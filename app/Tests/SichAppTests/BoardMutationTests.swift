import XCTest
@testable import SichApp
import SichCore

/// Model-level checks for the two new board mutations the user asked for:
/// add-task (create) and drag-to-column (move). The drag *gesture* itself is
/// an interaction AC for human sign-off; these prove the model the gesture drives.
@MainActor
final class BoardMutationTests: XCTestCase {
    /// Create appends a fresh, drillable (PTY-owning) live-terminal card.
    func testCreateSessionAppendsOwnedLiveCard() {
        let shell = BoardShell(seeds: Self.oneSeed())
        shell.buildContentForTesting()
        let before = shell.cards.count

        shell.createSession()

        XCTAssertEqual(shell.cards.count, before + 1)
        let new = try! XCTUnwrap(shell.cards.last)
        XCTAssertEqual(new.state, .idle, "a fresh terminal starts idle")
    }

    /// A created card carries the human task title and a readable slugged id —
    /// the fix for "every new card is an anonymous terminal-N".
    func testCreateSessionWithTitleNamesTheCard() {
        let shell = BoardShell(seeds: Self.oneSeed())
        shell.buildContentForTesting()

        shell.createSession(title: "Fix the login redirect")

        let new = try! XCTUnwrap(shell.cards.last)
        XCTAssertEqual(new.title, "Fix the login redirect", "card carries the task title")
        XCTAssertEqual(new.sessionID, "fix-the-login-redirect", "id slugged from the title, not terminal-N")
    }

    /// A created card opens in the chosen project folder, not always the repo root —
    /// the "title + project dir" create prompt the operator asked for.
    func testCreateSessionOpensInChosenProjectDir() {
        let shell = BoardShell(seeds: Self.oneSeed())
        shell.buildContentForTesting()

        shell.createSession(title: "Thing", projectDir: "/tmp/some-project")

        let new = try! XCTUnwrap(shell.cards.last)
        XCTAssertEqual(new.projectDir, "/tmp/some-project", "card opens in the chosen folder")
    }

    /// Dropping a card on a column sets its state to that column's state, keeping its
    /// identity (so a drilled-in terminal survives the move).
    func testMoveSetsColumnStatePreservingIdentity() {
        let shell = BoardShell(seeds: Self.oneSeed())
        shell.buildContentForTesting()
        let card = shell.cards[0]
        XCTAssertEqual(card.state, .running)

        shell.move(cardID: card.id, to: .done)

        let moved = try! XCTUnwrap(shell.cards.first { $0.id == card.id })
        XCTAssertEqual(moved.state, .done, "column.state inverse mapping applied")
        XCTAssertEqual(BoardColumn(state: moved.state), .done, "lands in the dropped column")
    }

    /// `inWorktree` runs the card in the provisioned checkout, not the chosen dir —
    /// the "worktree per task by default" seam (fake provisioner: no real git here).
    func testCreateSessionInWorktreeUsesProvisionedDir() {
        let shell = BoardShell(seeds: [])
        shell.buildContentForTesting()
        shell.worktreeProvisioner = FakeWorktreeProvisioner()

        shell.createSession(title: "Isolate me", projectDir: "/tmp/some-project", inWorktree: true)

        let card = try! XCTUnwrap(shell.cards.last)
        XCTAssertEqual(card.projectDir, "/tmp/worktrees/isolate-me",
                       "card lives in its own worktree, slugged from the title")
    }

    /// A provisioner miss (non-repo dir, git failure) falls back to the chosen dir —
    /// the worktree is an upgrade, never a gate on creating the card.
    func testCreateSessionInWorktreeFallsBackWhenProvisioningFails() {
        let shell = BoardShell(seeds: [])
        shell.buildContentForTesting()
        shell.worktreeProvisioner = FakeWorktreeProvisioner(succeeds: false)

        shell.createSession(title: "Thing", projectDir: "/tmp/some-project", inWorktree: true)

        XCTAssertEqual(shell.cards.last?.projectDir, "/tmp/some-project")
    }

    /// Rename swaps only the title — identity and state survive, so a renamed live
    /// task keeps its PTY binding (keyed by `id`) and its board column.
    func testRenamePreservesIdentityAndState() {
        let shell = BoardShell(seeds: Self.oneSeed())
        shell.buildContentForTesting()
        let card = shell.cards[0]

        shell.rename(cardID: card.id, to: "Ship the fix")

        let renamed = try! XCTUnwrap(shell.cards.first { $0.id == card.id })
        XCTAssertEqual(renamed.title, "Ship the fix")
        XCTAssertEqual(renamed.state, card.state, "rename never moves the card")
        XCTAssertEqual(renamed.sessionID, card.sessionID)
    }

    /// A blank rename clears the title so the card falls back to the project dir.
    func testRenameToBlankClearsTitle() {
        let shell = BoardShell(seeds: Self.oneSeed())
        shell.buildContentForTesting()
        shell.rename(cardID: shell.cards[0].id, to: "Named")
        XCTAssertNotNil(shell.cards[0].title)

        shell.rename(cardID: shell.cards[0].id, to: "   ")

        XCTAssertNil(shell.cards[0].title, "whitespace-only clears back to the dir fallback")
    }

    /// The card's context menu carries a Rename item, and dispatching it through the
    /// real NSMenu action path (not a direct handler call) fires `onRename`.
    func testCardContextMenuRenameItemFiresCallback() {
        let card = BoardCard(sessionID: "t", projectDir: "~/x", agent: .claude,
                             state: .idle)
        let view = SessionCard(card: card)
        var renamed: BoardCard?
        view.onRename = { renamed = $0 }

        let menu = try! XCTUnwrap(view.menu(for: NSEvent()))
        let idx = menu.items.firstIndex { $0.title.hasPrefix("Rename") }
        let itemIndex = try! XCTUnwrap(idx, "context menu has a Rename item")
        menu.performActionForItem(at: itemIndex)

        XCTAssertEqual(renamed?.id, card.id, "menu dispatch reached the rename callback")
    }

    /// Deleting a card removes it from the board and forgets its PTY binding — the
    /// "ability to delete task" the operator asked for.
    func testDeleteRemovesCardAndForgetsPTY() {
        let shell = BoardShell(seeds: [])
        shell.buildContentForTesting()
        shell.createSession(title: "Kill me")
        let card = try! XCTUnwrap(shell.cards.last)

        shell.deleteCard(cardID: card.id)

        XCTAssertNil(shell.cards.first { $0.id == card.id }, "card is gone from the board")
        XCTAssertNil(shell.ptyForTesting(card.id), "its PTY binding is forgotten")
    }

    /// Deleting a worktree-backed card tears down that checkout too, addressed at the
    /// exact checkout path the card lives in (US: "clean worktree when you delete").
    func testDeleteCleansWorktree() {
        let shell = BoardShell(seeds: [])
        shell.buildContentForTesting()
        let provisioner = RecordingWorktreeProvisioner()
        shell.worktreeProvisioner = provisioner
        shell.createSession(title: "Isolate me", projectDir: "/tmp/some-project", inWorktree: true)
        let card = try! XCTUnwrap(shell.cards.last)

        shell.deleteCard(cardID: card.id)

        XCTAssertEqual(provisioner.removed, ["/tmp/worktrees/isolate-me"],
                       "the card's worktree checkout is removed")
    }

    /// The card's context menu carries a Delete item, and dispatching it through the
    /// real NSMenu action path fires `onDelete` (interaction bound to a menu event).
    func testCardContextMenuDeleteItemFiresCallback() {
        let card = BoardCard(sessionID: "t", projectDir: "~/x", agent: .claude,
                             state: .idle)
        let view = SessionCard(card: card)
        var deleted: BoardCard?
        view.onDelete = { deleted = $0 }

        let menu = try! XCTUnwrap(view.menu(for: NSEvent()))
        let idx = try! XCTUnwrap(menu.items.firstIndex { $0.title.hasPrefix("Delete") },
                                 "context menu has a Delete item")
        menu.performActionForItem(at: idx)

        XCTAssertEqual(deleted?.id, card.id, "menu dispatch reached the delete callback")
    }

    /// Repo chip colours assign first-seen-first-slot: distinct repos get distinct
    /// hues (up to the palette size) and the same repo is stable across calls —
    /// the fix for hash-bucket collisions making two repos read as one.
    func testRepoColorsAreDistinctPerRepoAndStable() {
        let paths = (0..<8).map { "/Users/x/proj-\($0)" }
        let colors = paths.map { BoardTheme.repoColor($0) }

        XCTAssertEqual(Set(colors).count, paths.count, "first 8 repos never share a hue")
        XCTAssertEqual(BoardTheme.repoColor(paths[3]), colors[3], "same repo stays stable")
    }

    /// A stub seed (idles on `cat`, never an agentic CLI) — light enough for a unit test.
    static func oneSeed() -> [BoardSeed] {
        [BoardSeed(sessionID: "t", projectDir: "~/x", agent: .claude,
                   state: .running, scrollback: "")]
    }
}

/// Deterministic provisioner double — no git, no filesystem.
private struct FakeWorktreeProvisioner: WorktreeProvisioning {
    var succeeds = true
    func provision(repoDir: String, slug: String) -> ProvisionedWorktree? {
        succeeds ? ProvisionedWorktree(path: "/tmp/worktrees/\(slug)", branch: "task/\(slug)") : nil
    }
}

/// Records the worktree paths a delete asks to tear down, so a test can assert the
/// checkout is cleaned. Reference type: the shell holds it by value-of-protocol but
/// the class identity lets the test read back what was removed.
private final class RecordingWorktreeProvisioner: WorktreeProvisioning, @unchecked Sendable {
    private(set) var removed: [String] = []
    func provision(repoDir: String, slug: String) -> ProvisionedWorktree? {
        ProvisionedWorktree(path: "/tmp/worktrees/\(slug)", branch: "task/\(slug)")
    }
    func remove(worktreeAt path: String) -> Bool {
        removed.append(path)
        return true
    }
}
