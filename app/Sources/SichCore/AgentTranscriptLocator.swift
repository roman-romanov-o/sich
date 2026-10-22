import Foundation

/// Resolves on-disk agent transcript paths for harness/account handoffs.
/// Conversation ids do not port across agents; the new harness reads the prior
/// session's JSONL directly instead of inheriting a pasted terminal tail.
public enum AgentTranscriptLocator {

    public struct Request: Sendable, Equatable {
        public let agent: CardAgent
        public let projectDir: String
        public let claudeSessionID: UUID?
        public let claudeConfigRoot: String
        public let codexHome: String?
        public let cursorConfigRoot: String?

        public init(
            agent: CardAgent,
            projectDir: String,
            claudeSessionID: UUID? = nil,
            claudeConfigRoot: String = ClaudeLaunchEnv.defaultConfigDir.path,
            codexHome: String? = nil,
            cursorConfigRoot: String? = nil
        ) {
            self.agent = agent
            self.projectDir = projectDir
            self.claudeSessionID = claudeSessionID
            self.claudeConfigRoot = claudeConfigRoot
            self.codexHome = codexHome
            self.cursorConfigRoot = cursorConfigRoot
        }
    }

    /// Best-effort path to the prior harness's transcript file, or nil when none
    /// exists on disk yet.
    public static func locate(_ request: Request) -> String? {
        switch request.agent {
        case .claude:
            return claudeTranscript(
                configRoot: URL(fileURLWithPath: expanded(request.claudeConfigRoot), isDirectory: true),
                projectDir: request.projectDir,
                sessionID: request.claudeSessionID)
        case .codex:
            guard let home = request.codexHome else { return nil }
            return codexTranscript(codexHome: URL(fileURLWithPath: expanded(home), isDirectory: true))
        case .cursor:
            let root = URL(
                fileURLWithPath: expanded(request.cursorConfigRoot ?? "~/.cursor"), isDirectory: true)
            return cursorTranscript(configRoot: root, projectDir: request.projectDir)
        case .antigravity:
            return antigravityTranscript()
        case .gemini:
            return nil
        }
    }

    /// Construct the transcript path without checking the local filesystem — for
    /// remote handoffs where the file lives on the far-side machine.
    public static func expectedPath(_ request: Request) -> String? {
        switch request.agent {
        case .claude:
            let root = expanded(request.claudeConfigRoot)
            let dir = (root as NSString).appendingPathComponent("projects")
                + "/" + claudeProjectKey(for: request.projectDir)
            if let sessionID = request.claudeSessionID {
                return dir + "/\(sessionID.uuidString.lowercased()).jsonl"
            }
            return dir
        case .codex:
            guard let home = request.codexHome else { return nil }
            return expanded(home) + "/sessions"
        case .cursor:
            let root = expanded(request.cursorConfigRoot ?? "~/.cursor")
            return (root as NSString).appendingPathComponent("projects")
                + "/" + cursorProjectKey(for: request.projectDir)
                + "/agent-transcripts"
        case .antigravity:
            return expanded("~/.gemini/antigravity-cli/brain") + "/*/transcript.jsonl"
        case .gemini:
            return nil
        }
    }

    // MARK: - Claude

    /// `/Users/me/proj` → `-Users-me-proj` under `~/.claude/projects/`.
    public static func claudeProjectKey(for path: String) -> String {
        let expanded = expanded(path)
        if expanded.hasPrefix("/") {
            return "-" + expanded.dropFirst().replacingOccurrences(of: "/", with: "-")
        }
        return expanded.replacingOccurrences(of: "/", with: "-")
    }

    static func claudeTranscript(configRoot: URL, projectDir: String, sessionID: UUID?) -> String? {
        let dir = configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(claudeProjectKey(for: projectDir), isDirectory: true)
        if let sessionID {
            let exact = dir.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
            if FileManager.default.fileExists(atPath: exact.path) { return exact.path }
        }
        return newestJSONL(under: dir)
    }

    // MARK: - Codex

    static func codexTranscript(codexHome: URL) -> String? {
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        return CodexUsageReader.rolloutFiles(in: sessions).first?.path
    }

    // MARK: - Cursor

    /// `/Users/me/proj` → `Users-me-proj` under `~/.cursor/projects/`.
    public static func cursorProjectKey(for path: String) -> String {
        let expanded = expanded(path)
        let trimmed = expanded.hasPrefix("/") ? String(expanded.dropFirst()) : expanded
        return trimmed.replacingOccurrences(of: "/", with: "-")
    }

    static func cursorTranscript(configRoot: URL, projectDir: String) -> String? {
        let base = configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(cursorProjectKey(for: projectDir), isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        guard let walker = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var newest: (url: URL, mtime: Date)?
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            if newest.map({ mtime > $0.mtime }) ?? true { newest = (url, mtime) }
        }
        return newest?.url.path
    }

    // MARK: - Antigravity

    static func antigravityTranscript() -> String? {
        let brain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
        guard FileManager.default.fileExists(atPath: brain.path) else { return nil }
        guard let walker = FileManager.default.enumerator(
            at: brain,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var newest: (url: URL, mtime: Date)?
        for case let url as URL in walker {
            guard url.lastPathComponent == "transcript.jsonl" else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            if newest.map({ mtime > $0.mtime }) ?? true { newest = (url, mtime) }
        }
        return newest?.url.path
    }

    // MARK: - Helpers

    private static func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func newestJSONL(under dir: URL) -> String? {
        guard FileManager.default.fileExists(atPath: dir.path),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        var newest: (url: URL, mtime: Date)?
        for url in entries where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            if newest.map({ mtime > $0.mtime }) ?? true { newest = (url, mtime) }
        }
        return newest?.url.path
    }
}
