import AppKit
import SichCore
import Testing

@testable import SichApp

/// Arrow-key board navigation, driven by REAL keyDown `NSEvent`s through the
/// view (the Interaction-AC Binding Rule — never by calling helpers directly).
@MainActor
@Suite("Board keyboard navigation")
struct BoardKeyboardNavTests {

    private func makeBoard(cards: [BoardCard]) -> BoardView {
        let board = BoardView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        board.render(cards: cards)
        return board
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }

    @Test("right arrow walks focus across cards; Return drills into the focused one")
    func arrowsThenReturnSelects() throws {
        let a = BoardCard(sessionID: "a", projectDir: "~/a", agent: .claude, state: .running)
        let b = BoardCard(sessionID: "b", projectDir: "~/b", agent: .claude, state: .idle)
        let board = makeBoard(cards: [a, b])
        var selected: BoardCard?
        board.onSelect = { selected = $0 }

        #expect(board.acceptsFirstResponder)
        board.keyDown(with: try key(124))   // → focuses first card
        board.keyDown(with: try key(124))   // → second card
        board.keyDown(with: try key(36))    // Return drills in
        #expect(selected?.id == b.id)
    }

    @Test("focus survives a re-render and drops when the card disappears")
    func focusSurvivesRerender() throws {
        let a = BoardCard(sessionID: "a", projectDir: "~/a", agent: .claude, state: .running)
        let board = makeBoard(cards: [a])
        var selected: BoardCard?
        board.onSelect = { selected = $0 }

        board.keyDown(with: try key(124))   // focus the only card
        board.render(cards: [a])            // live refresh rebuilds card views
        board.keyDown(with: try key(36))
        #expect(selected?.id == a.id)

        board.render(cards: [])             // card gone → focus dropped
        selected = nil
        board.keyDown(with: try key(36))    // Return with no cards: no crash, no select
        #expect(selected == nil)
    }
}
