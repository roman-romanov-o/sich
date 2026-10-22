import Foundation
import Testing
@testable import SichCore

@Suite struct ClaudeUsageProbeTests {
    @Test func launchUsesAbsoluteShimPath() {
        let launch = ClaudeUsageProbe.spec(configDir: "~/.claude-personal").launch
        #expect(launch.contains("/.sich/bin/claude") || launch.contains("/.local/bin/claude"))
        #expect(!launch.hasPrefix("exec "))
    }

    /// Spawns real claude TUIs against this machine's two accounts. Opt in with
    /// `SICH_REAL_AGENT_E2E=1` — CI has no logged-in accounts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SICH_REAL_AGENT_E2E"] == "1"))
    func scrapeBothAccounts() async {
        HiddenTUIProbe.spawningEnabled = true
        defer { HiddenTUIProbe.spawningEnabled = false }
        for (label, dir) in [("default", nil as String?), ("personal", "~/.claude-personal")] {
            let r = ClaudeUsageProbe.scrape(deadline: 90, configDir: dir)
            #expect(r != nil, "\(label) scrape should succeed")
            if let r {
                print("\(label): session=\(r.sessionUsedPercent)% week=\(r.weekUsedPercent)%")
            }
        }
    }
}
