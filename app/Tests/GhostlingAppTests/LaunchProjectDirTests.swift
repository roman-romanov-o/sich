import Foundation
import Testing

@testable import GhostlingApp

/// Regression: launching the built .app from Finder starts the process with
/// cwd `/` (GUI apps inherit no shell cwd) and no repo root above it, which
/// seeded a permanent "/" live-terminal card on every launch. The launch dir
/// must never resolve to the filesystem root.
@Suite("Live-terminal launch dir (Finder-launch '/' card regression)")
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
