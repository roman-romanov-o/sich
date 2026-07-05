import XCTest
@testable import GhostlingApp

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
}
