import Foundation

/// Pure card-selection / drill-in routing state for the board (US-002 drill-in,
/// US-005 AC#2 filter-to-attention). Window-free and value-typed so the focus
/// routing is unit-testable without AppKit — the rendered board (`BoardView`)
/// owns this and reacts to it; the view never invents focus logic of its own.
///
/// "Selecting" a card is the logical half of US-002's drill-in (which session is
/// focused); the < 500 ms terminal-focus *interaction* is the view's job and
/// goes to visual sign-off, not a headless test.
public struct BoardSelection: Sendable, Equatable {

    /// The card the operator has drilled into, if any. `nil` = on the board.
    public private(set) var focusedCardID: UUID?

    /// When `true`, the board is filtered to the attention (waiting/blocked)
    /// cards — the US-005 AC#2 "activate the indicator → take me to the
    /// blockers" routing, expressed as pure state.
    public private(set) var attentionFilterActive: Bool

    public init(focusedCardID: UUID? = nil, attentionFilterActive: Bool = false) {
        self.focusedCardID = focusedCardID
        self.attentionFilterActive = attentionFilterActive
    }

    /// Drill into a card: focus it (US-002 AC#1, logical half). Idempotent.
    public mutating func focus(_ cardID: UUID) {
        focusedCardID = cardID
    }

    /// Return to the board, clearing the drilled-in focus (US-002 AC#2). The
    /// attention filter is intentionally preserved so "return to board" lands the
    /// operator back where they were routing from.
    public mutating func returnToBoard() {
        focusedCardID = nil
    }

    /// Activate the "who needs me" indicator: filter the board to the
    /// waiting/blocked cards (US-005 AC#2). No-op routing when count is `0`.
    public mutating func activateAttention(_ cards: [BoardCard]) {
        attentionFilterActive = !Attention.cards(cards).isEmpty
    }

    /// Clear the attention filter, showing the full board again.
    public mutating func clearAttentionFilter() {
        attentionFilterActive = false
    }

    /// The cards the board should display, honoring the attention filter.
    /// Without the filter this is the input unchanged; with it, only the
    /// waiting/blocked cards (US-005 AC#2).
    public func visibleCards(from cards: [BoardCard]) -> [BoardCard] {
        attentionFilterActive ? Attention.cards(cards) : cards
    }
}
