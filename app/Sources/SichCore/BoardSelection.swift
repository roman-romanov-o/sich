import Foundation

/// Pure card-selection / drill-in routing state for the board (US-002 drill-in).
/// Window-free and value-typed so the focus
/// routing is unit-testable without AppKit — the rendered board (`BoardView`)
/// owns this and reacts to it; the view never invents focus logic of its own.
///
/// "Selecting" a card is the logical half of US-002's drill-in (which session is
/// focused); the < 500 ms terminal-focus *interaction* is the view's job and
/// goes to visual sign-off, not a headless test.
public struct BoardSelection: Sendable, Equatable {

    /// The card the operator has drilled into, if any. `nil` = on the board.
    public private(set) var focusedCardID: UUID?

    public init(focusedCardID: UUID? = nil) {
        self.focusedCardID = focusedCardID
    }

    /// Drill into a card: focus it (US-002 AC#1, logical half). Idempotent.
    public mutating func focus(_ cardID: UUID) {
        focusedCardID = cardID
    }

    /// Return to the board, clearing the drilled-in focus (US-002 AC#2).
    public mutating func returnToBoard() {
        focusedCardID = nil
    }
}
