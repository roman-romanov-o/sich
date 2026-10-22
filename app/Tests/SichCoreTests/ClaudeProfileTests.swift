import Foundation
import Testing
@testable import SichCore

@Suite("ClaudeProfile")
struct ClaudeProfileTests {
    @Test("default profile uses interactive pool prefix and ~/.claude")
    func defaultProfilePools() {
        let profile = ClaudeProfile.defaultProfile
        #expect(profile.poolPrefix == "interactive")
        #expect(profile.pool5h == "interactive_5h")
        #expect(profile.quotaLabel == "claude")
        #expect(profile.isDefault)
    }

    @Test("named profile gets distinct pool prefix and quota label")
    func namedProfilePools() {
        let profile = ClaudeProfile(name: "Work", configDir: "~/.claude-work")
        #expect(profile.poolPrefix == "interactive_work")
        #expect(profile.quotaLabel == "claude · Work")
    }

    @Test("config dir export is empty for default and set for alternate dirs")
    func launchEnvExport() {
        #expect(ClaudeLaunchEnv.configDirExport("~/.claude").isEmpty)
        let alt = ClaudeLaunchEnv.configDirExport("~/.claude-work")
        #expect(alt.contains("CLAUDE_CONFIG_DIR="))
        #expect(alt.contains(".claude-work"))
    }

    @Test("profile store persists and reloads profiles")
    func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentAccountStore(url: dir, accounts: [.defaultClaude])
        _ = store.add(name: "Work", agent: .claude, configRoot: "~/.claude-work")
        let loaded = AgentAccountStore(url: dir)
        #expect(loaded.profiles.count == 2)
        #expect(loaded.profiles.contains { $0.name == "Work" })
    }
}
