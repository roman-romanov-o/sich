import XCTest
@testable import GhostlingApp
import GhostlingCore

/// Model-level checks for the two new board mutations the user asked for:
/// "+ new session" (create) and drag-to-column (move). The drag *gesture* itself is
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
        XCTAssertEqual(new.flow, .b, "live terminal is flow B (human-launched)")
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

    /// A stub seed (idles on `cat`, never an agentic CLI) — light enough for a unit test.
    static func oneSeed() -> [BoardSeed] {
        [BoardSeed(sessionID: "t", projectDir: "~/x", agent: .claude,
                   flow: .a, state: .running, scrollback: "")]
    }
}
