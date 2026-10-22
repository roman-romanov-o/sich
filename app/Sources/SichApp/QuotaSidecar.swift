import Foundation
import SichCore

/// The live quota feed — read IN-PROCESS, no sidecar, no HTTP (DD-001).
///
/// After the Phase-03 cutover there is no Python receiver and no localhost sidecar
/// wire: `NativeQuotaPoller` walks each Claude profile's transcript dir via
/// `SichCore` `QuotaUsageReader` and hands the resulting `[QuotaSourceInput]`
/// to the panel's sink.

// MARK: - Native quota polling (in-process, no HTTP)

@MainActor
public final class NativeQuotaPoller {
    private let interval: TimeInterval
    private let profiles: [ClaudeProfile]
    private let sink: ([QuotaSourceInput]) -> Void
    private var timer: Timer?
    private var inFlight = false

    init(
        interval: TimeInterval = 15,
        profiles: [ClaudeProfile] = [.defaultProfile],
        sink: @escaping ([QuotaSourceInput]) -> Void
    ) {
        self.interval = interval
        self.profiles = profiles.isEmpty ? [.defaultProfile] : profiles
        self.sink = sink
    }

    public func start() {
        primeProbes()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Kick a `/usage` scrape for every profile immediately so the first poll
    /// cycle is measuring, not a stale JSONL guess.
    private func primeProbes() {
        for profile in profiles {
            Task { @MainActor in _ = await ClaudeUsageProbe.probe(for: profile).current() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !inFlight else { return }
        inFlight = true
        let active = profiles
        Task.detached(priority: .utility) {
            let sources = await Self.liveOrEstimate(profiles: active)
            await MainActor.run { [weak self] in
                self?.inFlight = false
                self?.sink(sources)
            }
        }
    }

    static func liveOrEstimate(profiles: [ClaudeProfile]) async -> [QuotaSourceInput] {
        var sources: [QuotaSourceInput] = []

        if ProcessInfo.processInfo.environment["SICH_LIVE_USAGE"] != nil,
           let data = await UsageEndpointReader.fetch(),
           let live = UsageEndpointReader.interactiveSource(from: data) {
            sources = [live]
                + (UsageEndpointReader.interactiveDisplaySources(from: data) ?? [])
        } else {
            for profile in profiles {
                let prefix = profile.poolPrefix
                let projectsDir = profile.projectsDir
                let probe = await MainActor.run { ClaudeUsageProbe.probe(for: profile) }
                if let panel = await probe.current() {
                    sources += [ClaudeUsagePanel.interactiveSource(from: panel, poolPrefix: prefix)]
                    sources += ClaudeUsagePanel.interactiveDisplaySources(from: panel, poolPrefix: prefix)
                } else if !HiddenTUIProbe.spawningEnabled {
                    // Tests / offline only — the JSONL guess can read ~98% free while
                    // `/usage` shows 100% used, so never show it when probes are live.
                    let now = Date()
                    sources += QuotaUsageReader.readInteractiveSources(
                        now: now, projectsDir: projectsDir, poolPrefix: prefix)
                }
            }
        }
        sources += QuotaUsageReader.nonLocalSources

        if let codex = CodexUsageReader.source() {
            sources = sources.map { $0.provider == "codex" ? codex : $0 }
            if let display = CodexUsageReader.displaySources() {
                sources += display
            }
        }
        if let cursor = await CursorUsageProbe.shared.current() {
            let measured = CursorUsagePanel.source(from: cursor)
            sources = sources.map { $0.provider == "cursor" ? measured : $0 }
        }
        if let antigravity = await AntigravityUsageProbe.shared.current() {
            let measured = AntigravityUsagePanel.source(from: antigravity)
            sources = sources.map { $0.provider == "antigravity" ? measured : $0 }
            sources += AntigravityUsagePanel.displaySources(from: antigravity)
        }
        return sources
    }
}

// MARK: - Repo location

public enum RepoLocator {
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

    public static func launchProjectDir(
        repoRoot: URL? = RepoLocator.repoRoot(),
        cwd: String = FileManager.default.currentDirectoryPath,
        home: String = NSHomeDirectory()
    ) -> String {
        if let repoRoot { return repoRoot.path }
        return cwd == "/" ? home : cwd
    }
}
