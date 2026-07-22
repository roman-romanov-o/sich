import Foundation
import SichCore

/// The live quota feed — read IN-PROCESS, no sidecar, no HTTP (DD-001).
///
/// After the Phase-03 cutover there is no Python receiver and no localhost sidecar
/// wire: `NativeQuotaPoller` walks `~/.claude/projects/**/*.jsonl` directly via the
/// `SichCore` `QuotaUsageReader` and hands the resulting `[QuotaSourceInput]`
/// to the panel's sink. The `QuotaProjection` re-projects them exactly as before, so
/// the panel is unchanged; only the *origin* of the readings is native disk reads.
///
/// The two Anthropic pools stay independent source readings — nothing here nets one
/// pool against another. Watcher-not-spawner: it never spawns `claude -p` and binds
/// no port. The one deliberate process it starts is the quota-neutral hidden
/// `ClaudeUsageProbe` (`/usage` runs no model turn — zero tokens on either pool).

// MARK: - Native quota polling (in-process, no HTTP)

/// Reads quota IN-PROCESS on a timer — the native quota feed (DD-001). Each tick
/// walks `~/.claude/projects/**/*.jsonl` via the `SichCore` `QuotaUsageReader`
/// (the Swift port of the Python `jsonl_usage` + `live` source assembly) and hands
/// the resulting `[QuotaSourceInput]` to a main-actor sink — the panel and projection
/// are unchanged; only the origin of the readings is "read disk".
///
/// Watcher-not-spawner: it never spawns `claude -p` and binds no port. The file walk
/// runs off the main actor so a large transcript history can't stutter the UI; the
/// sink is called back on the main actor.
@MainActor
public final class NativeQuotaPoller {
    private let interval: TimeInterval
    private let projectsDir: URL
    private let sink: ([QuotaSourceInput]) -> Void
    private var timer: Timer?
    private var inFlight = false   // one detached read at a time — a slow tick never stacks

    public init(
        interval: TimeInterval = 15,
        projectsDir: URL = QuotaUsageReader.defaultProjectsDir,
        sink: @escaping ([QuotaSourceInput]) -> Void
    ) {
        self.interval = interval
        self.projectsDir = projectsDir
        self.sink = sink
    }

    public func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Each tick: the freshest source `liveOrEstimate` can offer — measured `/usage`
    /// scrape when available, JSONL estimate otherwise. Runs off the main actor so a
    /// big transcript history can't stutter the UI; the sink is called back on the
    /// main actor.
    private func tick() {
        guard !inFlight else { return }   // previous read still running — skip this tick
        inFlight = true
        let dir = projectsDir
        Task.detached(priority: .utility) {
            let sources = await Self.liveOrEstimate(projectsDir: dir)
            await MainActor.run { [weak self] in
                self?.inFlight = false
                self?.sink(sources)
            }
        }
    }

    /// Interactive-pool source, best first:
    ///  1. dev-only exact endpoint (`SICH_LIVE_USAGE`) — unshippable: reading
    ///     Claude Code's keychain item from OUR process triggers the macOS
    ///     credentials prompt on every launch (the ACL trusts only Claude Code);
    ///  2. the shipped measured path — `ClaudeUsageProbe`'s hidden `/usage` scrape
    ///     (claude reads its OWN keychain → no prompt; quota-neutral, zero tokens);
    ///  3. the JSONL token-count estimate, the honest floor when the probe has no
    ///     fresh reading yet (first ~2 ticks after launch, or claude not installed).
    static func liveOrEstimate(projectsDir: URL) async -> [QuotaSourceInput] {
        var sources: [QuotaSourceInput]
        if ProcessInfo.processInfo.environment["SICH_LIVE_USAGE"] != nil,
           let data = await UsageEndpointReader.fetch(),
           let live = UsageEndpointReader.interactiveSource(from: data) {
            sources = [live]
                + (UsageEndpointReader.interactiveDisplaySources(from: data) ?? [])
                + QuotaUsageReader.nonLocalSources
        } else if let panel = await ClaudeUsageProbe.shared.current() {
            sources = [ClaudeUsagePanel.interactiveSource(from: panel)]
                + ClaudeUsagePanel.interactiveDisplaySources(from: panel)
                + QuotaUsageReader.nonLocalSources
        } else {
            let now = Date()
            sources = QuotaUsageReader.read(now: now, projectsDir: projectsDir)
                + QuotaUsageReader.interactiveDisplaySources(now: now, projectsDir: projectsDir)
        }
        // Codex persists its own rate-limit telemetry on disk — swap the unknown
        // codex slot for the measured reading whenever a snapshot exists.
        if let codex = CodexUsageReader.source() {
            sources = sources.map { $0.provider == "codex" ? codex : $0 }
            if let display = CodexUsageReader.displaySources() {
                sources += display
            }
        }
        return sources
    }
}

// MARK: - Repo location

/// Resolves the repo root for the live-terminal cwd and the hook installer. No
/// Python, no port — just a filesystem walk. (Lived on `SidecarProcess` before the
/// cutover deleted the sidecar; the locator itself was never sidecar-specific.)
public enum RepoLocator {
    /// `$SICH_REPO_ROOT`, else walk up from CWD to the dir holding `pyproject.toml`.
    public static func repoRoot() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["SICH_REPO_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("pyproject.toml").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// The dir the daily launch seeds the live-terminal card with. A Finder/`open`
    /// launch starts the process at `/` — never a real project — which used to put
    /// a permanent "/" card on the board; fall back to the user's home instead.
    public static func launchProjectDir(
        repoRoot: URL? = RepoLocator.repoRoot(),
        cwd: String = FileManager.default.currentDirectoryPath,
        home: String = NSHomeDirectory()
    ) -> String {
        if let repoRoot { return repoRoot.path }
        return cwd == "/" ? home : cwd
    }
}
