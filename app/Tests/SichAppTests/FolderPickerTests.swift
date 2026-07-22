import XCTest
@testable import SichApp

/// Logic checks for the recent-folder picker (designer Approach A): the row facets
/// derived from a path, and the picker defaulting to the most-recent folder.
@MainActor
final class FolderPickerTests: XCTestCase {
    /// Leaf + initials come off the path; recency is the list order, not a stored time.
    func testRecentFolderDerivesLeafAndInitials() {
        let multi = RecentFolder(path: "/Users/jane/MyProjects/agentic-coding-kanban")
        XCTAssertEqual(multi.leaf, "agentic-coding-kanban")
        XCTAssertEqual(multi.initials, "ac", "first letters of the first two words")

        let single = RecentFolder(path: "/Users/jane/MyProjects/saha")
        XCTAssertEqual(single.initials, "sa", "single-word leaf falls back to first two chars")
    }

    /// Opening the prompt pre-selects the most-recent (first) folder, so the common
    /// case is "type a title, hit ↵" with no folder interaction at all.
    func testPickerDefaultsToMostRecentFolder() {
        let picker = FolderPickerView(recentDirs: ["/work/alpha", "/work/beta"])
        XCTAssertEqual(picker.selectedDir, "/work/alpha")
    }

    /// A `git worktree` checkout's `.git` is a *file* pointing at
    /// `<main-repo>/.git/worktrees/<name>`, not a directory containing `HEAD`
    /// directly. The branch chip must follow that indirection instead of
    /// silently reading nil.
    func testRecentFolderResolvesBranchThroughWorktreeGitFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderPickerTests-\(UUID().uuidString)", isDirectory: true)
        let worktreeGitDir = root.appendingPathComponent("main/.git/worktrees/task-05", isDirectory: true)
        let worktreeCheckout = root.appendingPathComponent("worktrees/task-05", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeCheckout, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "ref: refs/heads/task-05-feature\n".write(
            to: worktreeGitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )
        try "gitdir: \(worktreeGitDir.path)\n".write(
            to: worktreeCheckout.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        let folder = RecentFolder(path: worktreeCheckout.path)
        XCTAssertEqual(folder.branch, "task-05-feature")
    }
}
