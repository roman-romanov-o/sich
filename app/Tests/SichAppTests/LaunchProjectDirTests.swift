import Foundation
import Testing

@testable import SichApp

/// Regression: launching the built .app from Finder starts the process with
/// cwd `/` (GUI apps inherit no shell cwd) and no repo root above it. That dir is
/// now the DEFAULT PROJECT DIR for a card the operator creates (the launch no
/// longer seeds a card of its own), and it must never resolve to the filesystem
/// root — a card created from the palette would open its shell in `/`.
@Suite("Default project dir (Finder-launch '/' regression)")
struct LaunchProjectDirTests {

    @Test("Finder launch (cwd '/', no repo root) falls back to home, not '/'")
    func finderLaunchFallsBackToHome() {
        let dir = RepoLocator.launchProjectDir(repoRoot: nil, cwd: "/", home: "/Users/tester")
        #expect(dir == "/Users/tester")
    }

    @Test("terminal launch outside a repo keeps the shell's cwd")
    func terminalLaunchKeepsCwd() {
        let dir = RepoLocator.launchProjectDir(
            repoRoot: nil, cwd: "/Users/tester/somewhere", home: "/Users/tester"
        )
        #expect(dir == "/Users/tester/somewhere")
    }

    @Test("a resolved repo root wins over cwd")
    func repoRootWins() {
        let dir = RepoLocator.launchProjectDir(
            repoRoot: URL(fileURLWithPath: "/Users/tester/repo", isDirectory: true),
            cwd: "/", home: "/Users/tester"
        )
        #expect(dir == "/Users/tester/repo")
    }
}
