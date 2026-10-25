import Foundation
import Testing
@testable import SichCore

@Suite struct ClaudeUsageProbeTests {
    /// The probe runs under `zsh -lc` inside a GUI app, where bare `claude` is not on
    /// PATH — so the launch line must name the Sich shim by absolute path whenever it
    /// exists. Driven against a scratch home so the assertion does not depend on what
    /// the machine running the suite has installed.
    @Test func launchUsesAbsoluteShimPath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-probe-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let shim = home.appendingPathComponent(".sich/bin/claude")
        try FileManager.default.createDirectory(
            at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        let launch = ClaudeUsageProbe.spec(configDir: "~/.claude-personal", home: home).launch
        #expect(launch.contains(shim.path))
        #expect(!launch.hasPrefix("exec "))
    }

    /// No shim anywhere → fall back to `claude` on PATH rather than a dead absolute path.
    @Test func launchFallsBackToPathLookupWithoutAShim() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-probe-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let launch = ClaudeUsageProbe.spec(configDir: nil, home: home).launch
        #expect(launch == "'claude'")
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
