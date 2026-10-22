import Foundation

/// One named Claude Code account on this machine. Each profile maps to a distinct
/// ``CLAUDE_CONFIG_DIR`` — separate credentials, transcripts, and settings — so
/// several Anthropic subscriptions can run side by side without logging out.
public struct ClaudeProfile: Codable, Sendable, Equatable, Identifiable {
    /// The built-in profile for the default `~/.claude` config dir.
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public let id: UUID
    public var name: String
    /// Tilde-expandable path passed to `CLAUDE_CONFIG_DIR` (e.g. `~/.claude-work`).
    public var configDir: String

    public init(id: UUID = UUID(), name: String, configDir: String) {
        self.id = id
        self.name = name
        self.configDir = configDir
    }

    public var isDefault: Bool { id == Self.defaultID }

    /// Prefix for quota pool names (`interactive`, `interactive_work`, …).
    public var poolPrefix: String {
        isDefault ? "interactive" : "interactive_\(slug)"
    }

    public var pool5h: String { "\(poolPrefix)_5h" }
    public var poolWeekly: String { "\(poolPrefix)_weekly" }

    /// Label shown in the quota panel (`claude`, `claude · Work`, …).
    public var quotaLabel: String {
        isDefault ? "claude" : "claude · \(name)"
    }

    /// JSONL transcript root for this profile's usage estimate.
    public var projectsDir: URL {
        ClaudeLaunchEnv.projectsDir(forConfigDir: configDir)
    }

    public var resolvedConfigDir: String {
        ClaudeLaunchEnv.expanded(configDir)
    }

    private var slug: String {
        let lowered = name.lowercased()
        let cleaned = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let s = String(String.UnicodeScalarView(cleaned))
        return s.isEmpty ? "account" : s
    }

    public static var defaultProfile: ClaudeProfile {
        ClaudeProfile(id: defaultID, name: "Default", configDir: "~/.claude")
    }
}

/// Shell / launch helpers shared by the board seed, session restorer, and usage probes.
public enum ClaudeLaunchEnv {
    public static var defaultConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    public static func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public static func projectsDir(forConfigDir configDir: String) -> URL {
        URL(fileURLWithPath: expanded(configDir), isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// `CLAUDE_CONFIG_DIR=…` export for `/bin/sh -c` launch lines. Empty when default.
    public static func configDirExport(_ configDir: String?) -> String {
        guard let configDir else { return "" }
        let account = AgentAccountProfile(name: "", agent: .claude, configRoot: configDir)
        return AgentAccountBackend.shellEnvExports(for: account)
    }
}

extension AgentAccountStore {
    public var profiles: [ClaudeProfile] { claudeProfiles }
}
