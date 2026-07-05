import Foundation

/// Reads the REAL interactive-pool utilization by driving `claude` `/usage` in a
/// hidden pty and scraping the rendered panel (``ClaudeUsagePanel``).
///
/// Why a spawn is OK here (the deliberate exception to "starts no process"):
/// `/usage` runs no model turn — measured $0.00 / 0 tokens — so the probe is
/// quota-neutral on BOTH pools; the spawn is a plain interactive `claude` that
/// passes ``PoolFirewall`` (never `-p`). And it's the only prompt-free path to the
/// real number: when claude reads its own keychain credentials the ACL trusts it
/// (no dialog); our process reading them (`UsageEndpointReader`) is what triggers
/// the scary macOS prompt. We only ever read claude's screen.
///
/// The probe lives in a fixed dir (`~/.ghostling/usage-probe`) so the one-time
/// folder-trust answer persists and no project-level hooks ever fire — no ghost
/// cards on the board, and claude persists no transcript for a session with no
/// user turn.
public actor ClaudeUsageProbe {

    /// Positive opt-in set ONLY by real executable entry points (`ghostling`,
    /// `ghostling-probe usage`) — never by tests or `GHOSTLING_E2E`, so
    /// `swift test` can never spawn a claude process.
    /// nonisolated(unsafe): written once at process start, before any probe use.
    public nonisolated(unsafe) static var spawningEnabled = false

    public static let shared = ClaudeUsageProbe()

    /// Refresh every 5 min; serve a stale reading up to 15 min so one failed
    /// scrape doesn't flap the gauge back to the estimate.
    private static let refreshInterval: TimeInterval = 300
    private static let maxStale: TimeInterval = 900

    private var cached: ClaudeUsagePanel.Reading?
    private var fetchedAt: Date?
    private var running = false

    /// The current reading if fresh enough, kicking a background refresh when
    /// due. Returns immediately — the quota poller never waits on a spawn; the
    /// measured number lands on a later tick.
    public func current(now: Date = Date()) -> ClaudeUsagePanel.Reading? {
        let age = fetchedAt.map { now.timeIntervalSince($0) } ?? .infinity
        if age >= Self.refreshInterval { kickRefresh() }
        return age < Self.maxStale ? cached : nil
    }

    private func kickRefresh() {
        guard Self.spawningEnabled, !running else { return }
        running = true
        // GCD, not Task.detached: scrape() blocks for up to ~75s and must not
        // occupy a cooperative-pool thread that whole time.
        DispatchQueue.global(qos: .utility).async {
            let reading = Self.scrape()
            Task { await self.store(reading) }
        }
    }

    private func store(_ reading: ClaudeUsagePanel.Reading?) {
        running = false
        if let reading {
            cached = reading
            fetchedAt = Date()
        }
    }

    // MARK: - One scrape (blocking; call off the main actor)

    /// One full scrape: spawn a hidden `claude`, accept the trust dialog if it
    /// appears, wait for the input prompt, type `/usage`, and parse the panel.
    /// Returns nil on any failure (claude not installed, timeout, layout drift) —
    /// the caller falls back to the JSONL estimate, never a fake zero.
    public static func scrape(deadline: TimeInterval = 75) -> ClaudeUsagePanel.Reading? {
        guard spawningEnabled, let session = spawn() else { return nil }
        defer { session.terminate() }   // SIGKILL + reap — never leaks the hidden claude
        return drive(session, deadline: deadline)
    }

    private static var probeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghostling/usage-probe", isDirectory: true)
    }

    private static func spawn() -> PTYSession? {
        try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        // Login shell for PATH (a GUI app doesn't inherit the user's shell PATH);
        // 100 cols so the panel's "NN% used" column isn't wrapped mid-number.
        let cmd = ["/bin/zsh", "-lc", "cd \(shellQuoted(probeDir.path)) && exec claude"]
        guard let session = try? PTYSession(command: cmd, rows: 44, cols: 100),
              (try? session.start()) != nil else { return nil }
        session.setNonBlocking()
        return session
    }

    /// Poll the screen and walk the TUI: trust dialog → ready prompt → `/usage`
    /// → parse. Ready markers are version-dependent, so all three known forms.
    private static func drive(_ session: PTYSession, deadline: TimeInterval)
        -> ClaudeUsagePanel.Reading?
    {
        let end = Date().addingTimeInterval(deadline)
        var trusted = false
        var sent = false
        while Date() < end {
            if session.pumpAvailable() == .eof { return nil }
            guard let screen = try? session.terminal.plainText() else { return nil }
            if !trusted, screen.localizedCaseInsensitiveContains("trust this folder") {
                session.send([0x0D])       // accept the default "Yes, I trust this folder"
                trusted = true
            }
            if !sent, isReady(screen) {
                usleep(700_000)            // let the input box settle before typing
                session.send(Array("/usage".utf8))
                usleep(400_000)            // autocomplete needs a beat before Enter
                session.send([0x0D])
                sent = true
            }
            if sent, let reading = ClaudeUsagePanel.parse(screen: screen) {
                return reading
            }
            usleep(250_000)
        }
        return nil
    }

    private static func isReady(_ screen: String) -> Bool {
        screen.contains("? for shortcuts")
            || screen.contains("shift+tab to cycle")
            || screen.contains("Try \"")
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
