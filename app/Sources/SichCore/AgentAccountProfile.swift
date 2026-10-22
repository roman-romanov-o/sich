import Foundation

/// Whether a registered account has completed the agent's sign-in flow.
public enum AgentAccountAuthStatus: String, Codable, Sendable, Equatable {
    case pending
    case ready
    case unknown
}

/// One named agent account — Claude, Codex, or Cursor — on this machine or a remote
/// host. Each account maps to an isolated config root (`CLAUDE_CONFIG_DIR`,
/// `CODEX_HOME`, or `CURSOR_CONFIG_DIR`) so several subscriptions can run side by
/// side without logging out.
public struct AgentAccountProfile: Codable, Sendable, Equatable, Identifiable {
    public static let defaultClaudeID = ClaudeProfile.defaultID

    public let id: UUID
    public var name: String
    public var agent: CardAgent
    /// Tilde-expandable config root for this account (e.g. `~/.claude-work`).
    public var configRoot: String
    /// When set, credentials and hooks live on this ssh destination (`user@host`).
    public var host: String?
    public var authStatus: AgentAccountAuthStatus
    /// Codex-only overlay profile file stem inside ``configRoot`` (defaults to `sich-hooks`).
    public var codexProfileName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        agent: CardAgent,
        configRoot: String,
        host: String? = nil,
        authStatus: AgentAccountAuthStatus = .unknown,
        codexProfileName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.agent = agent
        self.configRoot = configRoot
        self.host = host
        self.authStatus = authStatus
        self.codexProfileName = codexProfileName
    }

    public var isDefault: Bool {
        id == Self.defaultClaudeID && agent == .claude && host == nil
    }

    public var resolvedConfigRoot: String {
        AgentAccountLaunchEnv.expanded(configRoot)
    }

    /// Path relative to remote `$HOME` for Claude-style settings (`.claude-work/settings.json`).
    public var settingsRelativePath: String? {
        AgentAccountBackend.settingsRelativePath(for: self)
    }

    /// The built-in default Claude account (`~/.claude` on this Mac).
    public static var defaultClaude: AgentAccountProfile {
        AgentAccountProfile(
            id: defaultClaudeID, name: "Default", agent: .claude, configRoot: "~/.claude")
    }

    /// Synthetic default for agents that support multi-account but have no stored row yet.
    public static func syntheticDefault(for agent: CardAgent, host: String? = nil) -> AgentAccountProfile? {
        guard AgentAccountBackend.supportsMultiAccount(agent) else { return nil }
        switch agent {
        case .claude:
            guard host == nil else {
                return AgentAccountProfile(
                    name: "Default", agent: .claude, configRoot: "~/.claude", host: host)
            }
            return .defaultClaude
        case .codex:
            return AgentAccountProfile(
                name: "Default", agent: .codex, configRoot: "~/.codex", host: host)
        case .cursor:
            return AgentAccountProfile(
                name: "Default", agent: .cursor, configRoot: "~/.cursor", host: host)
        case .gemini, .antigravity:
            return nil
        }
    }
}

extension AgentAccountProfile {
    /// Quota-panel view for Claude accounts (non-Claude kinds return nil).
    public var claudeProfile: ClaudeProfile? {
        guard agent == .claude else { return nil }
        return ClaudeProfile(id: id, name: name, configDir: configRoot)
    }
}

/// Per-agent account mechanics — env exports, login commands, auth markers, and
/// suggested paths. Hook installation stays in SichApp's ``HookInstaller``; this
/// registry is the extendable contract new LLM clients plug into.
public enum AgentAccountBackend {
    public static let codexHookProfileName = "sich-hooks"

    public static func supportsMultiAccount(_ agent: CardAgent) -> Bool {
        switch agent {
        case .claude, .codex, .cursor: return true
        case .gemini, .antigravity: return false
        }
    }

    public static func displayName(for agent: CardAgent) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        }
    }

    public static func suggestedConfigRoot(agent: CardAgent, name: String) -> String {
        let slug = slugify(name)
        switch agent {
        case .claude: return "~/.claude-\(slug)"
        case .codex: return "~/.codex-\(slug)"
        case .cursor: return "~/.cursor-\(slug)"
        case .gemini, .antigravity: return "~/.sich/\(agent.rawValue)-\(slug)"
        }
    }

    public static func defaultConfigRoot(for agent: CardAgent) -> String {
        switch agent {
        case .claude: return "~/.claude"
        case .codex: return "~/.codex"
        case .cursor: return "~/.cursor"
        case .gemini: return "~/.gemini"
        case .antigravity: return "~/.gemini"
        }
    }

    public static func isDefaultConfigRoot(_ root: String, agent: CardAgent) -> Bool {
        AgentAccountLaunchEnv.expanded(root) == AgentAccountLaunchEnv.expanded(defaultConfigRoot(for: agent))
    }

    /// Shell prefix exports for launch / restore (`CLAUDE_CONFIG_DIR=… CODEX_HOME=…`).
    public static func shellEnvExports(for account: AgentAccountProfile) -> String {
        switch account.agent {
        case .claude:
            guard !isDefaultConfigRoot(account.configRoot, agent: .claude) else { return "" }
            return "CLAUDE_CONFIG_DIR=\(shellQuoted(account.resolvedConfigRoot)) "
        case .codex:
            guard !isDefaultConfigRoot(account.configRoot, agent: .codex) else { return "" }
            let profile = account.codexProfileName ?? codexHookProfileName
            return "CODEX_HOME=\(shellQuoted(account.resolvedConfigRoot)) "
                + "SICH_CODEX_PROFILE=\(shellQuoted(profile)) "
        case .cursor:
            guard !isDefaultConfigRoot(account.configRoot, agent: .cursor) else { return "" }
            return "CURSOR_CONFIG_DIR=\(shellQuoted(account.resolvedConfigRoot)) "
        case .gemini, .antigravity:
            return ""
        }
    }

    /// Resolve exports for a stored id; empty when unknown or default.
    public static func shellEnvExports(
        accountID: UUID?, in accounts: [AgentAccountProfile], agent: CardAgent
    ) -> String {
        guard let accountID,
              let account = accounts.first(where: { $0.id == accountID }),
              account.agent == agent
        else { return "" }
        return shellEnvExports(for: account)
    }

    /// Keystrokes typed into a fresh login shell to start browser / OAuth sign-in.
    public static func loginCommand(for account: AgentAccountProfile, localShim: Bool) -> String {
        switch account.agent {
        case .claude:
            let claude = localShim ? "\"$HOME/.sich/bin/claude\"" : "claude"
            return "\(claude)\n/login\n"
        case .codex:
            let codex = localShim ? "\"$HOME/.sich/bin/codex\"" : "codex"
            return "\(codex) login\n"
        case .cursor:
            let agentBin = localShim ? "\"$HOME/.sich/bin/agent\"" : "agent"
            return "\(agentBin) login\n"
        case .gemini, .antigravity:
            return ""
        }
    }

    /// Relative paths under ``configRoot`` that indicate a completed login.
    public static func authMarkerPaths(for account: AgentAccountProfile) -> [String] {
        switch account.agent {
        case .claude:
            return [".credentials.json", "credentials.json"]
        case .codex:
            return ["auth.json"]
        case .cursor:
            return ["auth.json", "credentials.json", "cli-config.json"]
        case .gemini, .antigravity:
            return []
        }
    }

    public static func isAuthenticated(_ account: AgentAccountProfile) -> Bool {
        let root = URL(fileURLWithPath: account.resolvedConfigRoot, isDirectory: true)
        return authMarkerPaths(for: account).contains {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    public static func refreshedAuthStatus(for account: AgentAccountProfile) -> AgentAccountAuthStatus {
        isAuthenticated(account) ? .ready : (account.authStatus == .pending ? .pending : .unknown)
    }

    /// `$HOME`-relative settings path for remote hook install (Claude/Cursor only).
    public static func settingsRelativePath(for account: AgentAccountProfile) -> String? {
        let root = account.configRoot.trimmingCharacters(in: .whitespaces)
        guard root.hasPrefix("~/") else { return nil }
        let tail = String(root.dropFirst(2))
        guard isSafeHomeRelative(tail) else { return nil }
        switch account.agent {
        case .claude:
            return "\(tail)/settings.json"
        case .cursor:
            return "\(tail)/hooks.json"
        case .codex:
            let profile = account.codexProfileName ?? codexHookProfileName
            return "\(tail)/\(profile).config.toml"
        case .gemini, .antigravity:
            return nil
        }
    }

    /// tmux `set-environment` pairs for a remote attach (survives new panes).
    public static func remoteTmuxEnvironment(for account: AgentAccountProfile) -> [(String, String)] {
        switch account.agent {
        case .claude where !isDefaultConfigRoot(account.configRoot, agent: .claude):
            return [("CLAUDE_CONFIG_DIR", account.resolvedConfigRoot)]
        case .codex where !isDefaultConfigRoot(account.configRoot, agent: .codex):
            let profile = account.codexProfileName ?? codexHookProfileName
            return [
                ("CODEX_HOME", account.resolvedConfigRoot),
                ("SICH_CODEX_PROFILE", profile),
            ]
        case .cursor where !isDefaultConfigRoot(account.configRoot, agent: .cursor):
            return [("CURSOR_CONFIG_DIR", account.resolvedConfigRoot)]
        default:
            return []
        }
    }

    private static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let cleaned = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let s = String(String.UnicodeScalarView(cleaned))
        return s.isEmpty ? "account" : s
    }

    private static func isSafeHomeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("..")
            && path.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-_./".unicodeScalars.contains($0)
            }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Shell / launch helpers shared by the board seed, session restorer, and usage probes.
enum AgentAccountLaunchEnv {
    static func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

/// Persists named agent accounts under `~/.sich/agent-accounts.json`, migrating
/// legacy `claude-profiles.json` on first load.
public final class AgentAccountStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public private(set) var accounts: [AgentAccountProfile]

    public init(
        url: URL = AgentAccountStore.defaultURL,
        accounts: [AgentAccountProfile]? = nil
    ) {
        self.url = url
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        if let accounts {
            self.accounts = accounts
        } else if let loaded = Self.load(from: url, decoder: decoder) {
            self.accounts = loaded
        } else if let migrated = Self.migrateLegacyClaudeProfiles(decoder: decoder) {
            self.accounts = migrated
            save()
        } else {
            self.accounts = [.defaultClaude]
        }
        ensureDefaultClaudePresent()
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sich/agent-accounts.json")
    }

    /// Claude-only rows for the quota panel (includes the built-in default).
    public var claudeProfiles: [ClaudeProfile] {
        accounts.compactMap(\.claudeProfile)
    }

    public func account(id: UUID?) -> AgentAccountProfile? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    /// Accounts selectable for a harness on a given destination (local or remote host).
    public func selectable(for agent: CardAgent, host: String?) -> [AgentAccountProfile] {
        guard AgentAccountBackend.supportsMultiAccount(agent) else { return [] }
        let stored = accounts.filter { $0.agent == agent && $0.host == host }
        if stored.contains(where: { AgentAccountBackend.isDefaultConfigRoot($0.configRoot, agent: agent) }) {
            return stored
        }
        if let synthetic = AgentAccountProfile.syntheticDefault(for: agent, host: host) {
            return [synthetic] + stored.filter { $0.id != synthetic.id }
        }
        return stored
    }

    @discardableResult
    public func add(
        name: String,
        agent: CardAgent,
        configRoot: String,
        host: String? = nil,
        codexProfileName: String? = nil
    ) -> AgentAccountProfile {
        var account = AgentAccountProfile(
            name: name, agent: agent, configRoot: configRoot, host: host,
            authStatus: .pending, codexProfileName: codexProfileName)
        account.authStatus = AgentAccountBackend.isAuthenticated(account) ? .ready : .pending
        accounts.append(account)
        save()
        return account
    }

    public func remove(id: UUID) {
        guard id != AgentAccountProfile.defaultClaudeID else { return }
        accounts.removeAll { $0.id == id }
        save()
    }

    public func refreshAuthStatus(id: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].authStatus = AgentAccountBackend.refreshedAuthStatus(for: accounts[idx])
        save()
    }

    private func ensureDefaultClaudePresent() {
        guard !accounts.contains(where: { $0.isDefault }) else { return }
        accounts.insert(.defaultClaude, at: 0)
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(accounts).write(to: url, options: .atomic)
    }

    private static func load(from url: URL, decoder: JSONDecoder) -> [AgentAccountProfile]? {
        guard let data = try? Data(contentsOf: url),
              let accounts = try? decoder.decode([AgentAccountProfile].self, from: data),
              !accounts.isEmpty
        else { return nil }
        return accounts
    }

    private static func migrateLegacyClaudeProfiles(decoder: JSONDecoder) -> [AgentAccountProfile]? {
        let legacyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sich/claude-profiles.json")
        guard let data = try? Data(contentsOf: legacyURL),
              let profiles = try? decoder.decode([ClaudeProfile].self, from: data),
              !profiles.isEmpty
        else { return nil }
        return profiles.map {
            let account = AgentAccountProfile(
                id: $0.id, name: $0.name, agent: .claude, configRoot: $0.configDir)
            return AgentAccountProfile(
                id: account.id, name: account.name, agent: account.agent,
                configRoot: account.configRoot,
                authStatus: AgentAccountBackend.isAuthenticated(account) ? .ready : .unknown)
        }
    }
}
