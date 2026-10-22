import Foundation

/// Process-wide opt-in for the hidden-pty usage probes. Set ONLY by real
/// executable entry points (`sich`, `sich-probe`) — never by tests or `SICH_E2E`,
/// so `swift test` can never spawn a `claude` or `agent` process.
/// nonisolated(unsafe): written once at process start, before any probe use.
public enum HiddenTUIProbe {
    public nonisolated(unsafe) static var spawningEnabled = false

    /// The fixed dir every probe runs in, so a one-time folder-trust answer
    /// persists and no project-level hooks ever fire (no ghost cards on the board).
    public static var probeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sich/usage-probe", isDirectory: true)
    }
}

/// How to drive one agent's TUI to its usage panel: what to launch, how to tell
/// the input prompt is ready, and how to read the rendered screen.
public struct TUIUsageProbeSpec<Reading: Sendable>: Sendable {
    /// Shell command executed inside ``HiddenTUIProbe/probeDir`` by a login shell
    /// (a GUI app doesn't inherit the user's shell PATH).
    public let launch: String
    /// Any of these on screen means the input box accepts a slash command.
    public let readyMarkers: [String]
    /// Case-insensitive text of a folder-trust dialog to accept with Enter, if
    /// the agent shows one (nil when the launch command already trusts the dir).
    public let trustPrompt: String?
    public let parse: @Sendable (String) -> Reading?

    public init(launch: String, readyMarkers: [String], trustPrompt: String?,
                parse: @escaping @Sendable (String) -> Reading?) {
        self.launch = launch
        self.readyMarkers = readyMarkers
        self.trustPrompt = trustPrompt
        self.parse = parse
    }
}

/// Reads an agent's REAL quota by driving its own `/usage` command in a hidden
/// pty and scraping the rendered panel — the same numbers the CLI shows its user.
///
/// Why a spawn is OK here (the deliberate exception to "starts no process"):
/// `/usage` runs no model turn — measured $0.00 / 0 tokens — so the probe is
/// quota-neutral; the spawn is a plain interactive CLI that passes ``PoolFirewall``
/// (never `-p`). And it's the only prompt-free path to the real number: when the
/// CLI reads its own credentials the keychain ACL trusts it (no dialog); our
/// process reading them is what triggers the scary macOS prompt. We only ever
/// read the agent's screen.
public actor TUIUsageProbe<Reading: Sendable> {
    /// Refresh every 5 min; serve a stale reading up to 15 min so one failed
    /// scrape doesn't flap the gauge back to the fallback.
    private static var refreshInterval: TimeInterval { 300 }
    private static var maxStale: TimeInterval { 900 }

    private let spec: TUIUsageProbeSpec<Reading>
    private var cached: Reading?
    private var fetchedAt: Date?
    private var running = false

    public init(spec: TUIUsageProbeSpec<Reading>) {
        self.spec = spec
    }

    /// The current reading if fresh enough, kicking a background refresh when
    /// due. Returns immediately — the quota poller never waits on a spawn; the
    /// measured number lands on a later tick.
    public func current(now: Date = Date()) -> Reading? {
        let age = fetchedAt.map { now.timeIntervalSince($0) } ?? .infinity
        if age >= Self.refreshInterval { kickRefresh() }
        return age < Self.maxStale ? cached : nil
    }

    private func kickRefresh() {
        guard HiddenTUIProbe.spawningEnabled, !running else { return }
        running = true
        let spec = self.spec
        // GCD, not Task.detached: scrape() blocks for up to ~75s and must not
        // occupy a cooperative-pool thread that whole time.
        DispatchQueue.global(qos: .utility).async {
            let reading = Self.scrape(spec: spec)
            Task { await self.store(reading) }
        }
    }

    private func store(_ reading: Reading?) {
        running = false
        if let reading {
            cached = reading
            fetchedAt = Date()
        }
    }

    // MARK: - One scrape (blocking; call off the main actor)

    /// One full scrape: spawn the hidden CLI, accept the trust dialog if it
    /// appears, wait for the input prompt, type `/usage`, and parse the panel.
    /// Returns nil on any failure (CLI not installed, timeout, layout drift) —
    /// the caller keeps its fallback, never a fake zero.
    public static func scrape(spec: TUIUsageProbeSpec<Reading>, deadline: TimeInterval = 75) -> Reading? {
        guard HiddenTUIProbe.spawningEnabled, let session = spawn(spec) else { return nil }
        defer { session.terminate() }   // SIGKILL + reap — never leaks the hidden CLI
        return drive(session, spec: spec, deadline: deadline)
    }

    private static func spawn(_ spec: TUIUsageProbeSpec<Reading>) -> PTYSession? {
        let dir = HiddenTUIProbe.probeDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 100 cols so the panel's "NN% used" column isn't wrapped mid-number.
        // No `exec` — `exec CLAUDE_CONFIG_DIR=… claude` makes zsh treat the env
        // assignment as the executable name, so every non-default Claude profile's
        // probe dies instantly and the panel falls back to the JSONL estimate.
        let cmd = ["/bin/zsh", "-lc", "cd \(shellQuoted(dir.path)) && \(spec.launch)"]
        guard let session = try? PTYSession(command: cmd, rows: 44, cols: 100),
              (try? session.start()) != nil else { return nil }
        session.setNonBlocking()
        return session
    }

    /// Poll the screen and walk the TUI: trust dialog → ready prompt → `/usage` → parse.
    private static func drive(_ session: PTYSession, spec: TUIUsageProbeSpec<Reading>,
                              deadline: TimeInterval) -> Reading? {
        let end = Date().addingTimeInterval(deadline)
        var trusted = spec.trustPrompt == nil
        var sent = false
        while Date() < end {
            if session.pumpAvailable() == .eof { return nil }
            guard let screen = try? session.terminal.plainText() else { return nil }
            if !trusted, let prompt = spec.trustPrompt, screen.localizedCaseInsensitiveContains(prompt) {
                // The dialog highlights "No, exit" first — Down selects "Yes, I trust".
                session.send([0x1B, 0x5B, 0x42])
                usleep(200_000)
                session.send([0x0D])
                trusted = true
            }
            if !sent, spec.readyMarkers.contains(where: screen.contains) {
                usleep(700_000)            // let the input box settle before typing
                session.send(Array("/usage".utf8))
                usleep(400_000)            // autocomplete needs a beat before Enter
                session.send([0x0D])
                sent = true
            }
            if sent, let reading = spec.parse(screen) {
                return reading
            }
            usleep(250_000)
        }
        return nil
    }


    // MARK: - Exploration (sich-probe only)

    /// Print the rendered screen every 3s for `seconds`, typing `keysAfterHalf`
    /// (`\n` = Enter) once halfway through — a discovery aid for new agent specs.
    public static func dumpScreens(launch: String, seconds: TimeInterval, keysAfterHalf: String) {
        let spec = TUIUsageProbeSpec<Reading>(launch: launch, readyMarkers: [], trustPrompt: nil, parse: { _ in nil })
        guard let session = spawn(spec) else { print("spawn failed"); return }
        defer { session.terminate() }
        let start = Date()
        var typed = keysAfterHalf.isEmpty
        var lastDump = Date.distantPast
        while Date().timeIntervalSince(start) < seconds {
            if session.pumpAvailable() == .eof { print("[eof]"); break }
            if !typed, Date().timeIntervalSince(start) > seconds / 2 {
                for ch in keysAfterHalf.replacingOccurrences(of: "\\n", with: "\r") {
                    session.send(Array(String(ch).utf8)); usleep(120_000)
                }
                typed = true
            }
            if Date().timeIntervalSince(lastDump) > 3 {
                let screen = (try? session.terminal.plainText()) ?? ""
                print("---- t=\(Int(Date().timeIntervalSince(start)))s ----")
                print(screen.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n"))
                lastDump = Date()
            }
            usleep(200_000)
        }
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
