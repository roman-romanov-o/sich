import Foundation
import Testing

@testable import SichCore

@Suite("Agent transcript locator")
struct AgentTranscriptLocatorTests {

    @Test("Claude project keys match the CLI layout")
    func claudeProjectKey() {
        #expect(AgentTranscriptLocator.claudeProjectKey(for: "/Users/me/proj")
                == "-Users-me-proj")
    }

    @Test("Cursor project keys match the CLI layout")
    func cursorProjectKey() {
        #expect(AgentTranscriptLocator.cursorProjectKey(for: "/Users/me/proj")
                == "Users-me-proj")
    }

    @Test("Claude transcript resolves by session id")
    func claudeBySessionID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID(uuidString: "2ff3c59c-74da-48ff-be75-f68c5ad50d9d")!
        let dir = root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-tmp-work", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(session.uuidString.lowercased()).jsonl")
        try "{}".write(to: file, atomically: true, encoding: .utf8)

        let path = AgentTranscriptLocator.locate(
            AgentTranscriptLocator.Request(
                agent: .claude, projectDir: "/tmp/work",
                claudeSessionID: session, claudeConfigRoot: root.path))
        #expect(path?.hasSuffix("\(session.uuidString.lowercased()).jsonl") == true)
    }

    @Test("expectedPath constructs remote transcript locations without local checks")
    func expectedPathForRemote() {
        let session = UUID(uuidString: "2ff3c59c-74da-48ff-be75-f68c5ad50d9d")!
        let path = AgentTranscriptLocator.expectedPath(
            AgentTranscriptLocator.Request(
                agent: .claude, projectDir: "/home/dev/proj",
                claudeSessionID: session, claudeConfigRoot: "~/.claude"))
        #expect(path?.contains("2ff3c59c-74da-48ff-be75-f68c5ad50d9d.jsonl") == true)
        #expect(path?.contains("-home-dev-proj") == true)
    }

    @Test("Codex transcript picks the newest rollout")
    func codexNewestRollout() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2026/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let older = day.appendingPathComponent("rollout-old.jsonl")
        let newer = day.appendingPathComponent("rollout-new.jsonl")
        try Data("{}".utf8).write(to: older)
        try Data("{}".utf8).write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path)

        let path = AgentTranscriptLocator.locate(
            AgentTranscriptLocator.Request(agent: .codex, projectDir: "/tmp", codexHome: home.path))
        #expect(path?.hasSuffix("rollout-new.jsonl") == true)
    }
}
