import Foundation

/// The interactive-pool probe: a hidden `claude`, its `/usage` panel read by
/// ``ClaudeUsagePanel``. Ready markers are version-dependent, so all three known forms.
public enum ClaudeUsageProbe {
    public static func spec(configDir: String? = nil) -> TUIUsageProbeSpec<ClaudeUsagePanel.Reading> {
        ensureUsageProbeTrusted(configDir: configDir)
        let launch = launchCommand(configDir: configDir)
        return TUIUsageProbeSpec(
            launch: launch,
            readyMarkers: ["? for shortcuts", "shift+tab to cycle", "Try \""],
            trustPrompt: "one you trust",
            parse: { ClaudeUsagePanel.parse(screen: $0) }
        )
    }

    @MainActor
    private static var probes: [String: TUIUsageProbe<ClaudeUsagePanel.Reading>] = [:]

    /// One cached probe per config dir so each account's `/usage` scrape stays isolated.
    @MainActor
    public static func probe(for profile: ClaudeProfile) -> TUIUsageProbe<ClaudeUsagePanel.Reading> {
        let key = profile.resolvedConfigDir
        if let existing = probes[key] { return existing }
        let created = TUIUsageProbe(spec: spec(configDir: profile.configDir))
        probes[key] = created
        return created
    }

    public static func scrape(deadline: TimeInterval = 75, configDir: String? = nil) -> ClaudeUsagePanel.Reading? {
        TUIUsageProbe.scrape(spec: spec(configDir: configDir), deadline: deadline)
    }

    private static func launchCommand(configDir: String?) -> String {
        let claude = shellQuoted(resolvedClaudeExecutable())
        let export = ClaudeLaunchEnv.configDirExport(configDir)
        return export.isEmpty ? claude : "\(export.trimmingCharacters(in: .whitespaces)) \(claude)"
    }

    /// The hidden probe runs under `/bin/zsh -lc` inside a GUI app — bare `claude`
    /// is not on PATH. Prefer the same Sich shim the board uses for card launches.
    private static func resolvedClaudeExecutable() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".sich/bin/claude"),
            home.appendingPathComponent(".local/bin/claude"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url.path
        }
        return "claude"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Each ``CLAUDE_CONFIG_DIR`` keeps its own trusted-project list. The hidden
    /// probe always runs in ``HiddenTUIProbe/probeDir``; without seeding trust
    /// here, non-default profiles stall on the safety dialog and never reach `/usage`.
    static func ensureUsageProbeTrusted(configDir: String?) {
        let root = URL(fileURLWithPath: ClaudeLaunchEnv.expanded(configDir ?? "~/.claude"), isDirectory: true)
        let jsonURL = root.appendingPathComponent(".claude.json")
        let probePath = HiddenTUIProbe.probeDir.path
        var rootObject: [String: Any]
        if let data = try? Data(contentsOf: jsonURL),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rootObject = decoded
        } else {
            rootObject = [:]
        }
        var projects = rootObject["projects"] as? [String: Any] ?? [:]
        if let entry = projects[probePath] as? [String: Any],
           entry["hasTrustDialogAccepted"] as? Bool == true { return }
        var entry = projects[probePath] as? [String: Any] ?? [:]
        entry["hasTrustDialogAccepted"] = true
        projects[probePath] = entry
        rootObject["projects"] = projects
        guard JSONSerialization.isValidJSONObject(rootObject),
              let data = try? JSONSerialization.data(withJSONObject: rootObject, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }
}
