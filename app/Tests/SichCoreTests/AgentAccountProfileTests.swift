import Foundation
import Testing
@testable import SichCore

@Suite("AgentAccountProfile")
struct AgentAccountProfileTests {
    @Test("Claude export uses CLAUDE_CONFIG_DIR for alternate roots")
    func claudeEnvExport() {
        let account = AgentAccountProfile(name: "Work", agent: .claude, configRoot: "~/.claude-work")
        let env = AgentAccountBackend.shellEnvExports(for: account)
        #expect(env.contains("CLAUDE_CONFIG_DIR="))
        #expect(env.contains(".claude-work"))
    }

    @Test("Codex export uses CODEX_HOME and SICH_CODEX_PROFILE")
    func codexEnvExport() {
        let account = AgentAccountProfile(name: "Work", agent: .codex, configRoot: "~/.codex-work")
        let env = AgentAccountBackend.shellEnvExports(for: account)
        #expect(env.contains("CODEX_HOME="))
        #expect(env.contains("SICH_CODEX_PROFILE="))
    }

    @Test("Cursor export uses CURSOR_CONFIG_DIR")
    func cursorEnvExport() {
        let account = AgentAccountProfile(name: "Work", agent: .cursor, configRoot: "~/.cursor-work")
        let env = AgentAccountBackend.shellEnvExports(for: account)
        #expect(env.contains("CURSOR_CONFIG_DIR="))
    }

    @Test("login commands cover Claude, Codex, and Cursor")
    func loginCommands() {
        let claude = AgentAccountProfile(name: "A", agent: .claude, configRoot: "~/.claude-a")
        #expect(AgentAccountBackend.loginCommand(for: claude, localShim: true).contains("/login"))
        let codex = AgentAccountProfile(name: "B", agent: .codex, configRoot: "~/.codex-b")
        #expect(AgentAccountBackend.loginCommand(for: codex, localShim: true).contains("login"))
        let cursor = AgentAccountProfile(name: "C", agent: .cursor, configRoot: "~/.cursor-c")
        #expect(AgentAccountBackend.loginCommand(for: cursor, localShim: true).contains("login"))
    }

    @Test("store persists and reloads multi-agent accounts")
    func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-accounts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentAccountStore(url: dir, accounts: [.defaultClaude])
        _ = store.add(name: "Work Codex", agent: .codex, configRoot: "~/.codex-work")
        let loaded = AgentAccountStore(url: dir)
        #expect(loaded.accounts.count == 2)
        #expect(loaded.accounts.contains { $0.agent == .codex && $0.name == "Work Codex" })
    }
}
