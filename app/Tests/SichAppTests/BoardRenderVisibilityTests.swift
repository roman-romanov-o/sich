import AppKit
import SichCore
import Testing

@testable import SichApp

/// Conservation law for the board: a card that exists in the model must render
/// exactly one card on the view — for EVERY `(state, flow)` it can have. The bug
/// that motivated this: a card whose state decayed to `.unknown` (agent quit with
/// no Stop/SessionEnd hook, then the 30s stale sweep) mapped to a board column
/// `BoardView` had no cell for, so `render` silently `continue`d past it and the
/// card VANISHED ("I quit the task and it just disappeared").
///
/// The old `BoardPlacementTests` only proved `state → column` at the model layer
/// (a pure dict that can't drop a card); nothing drove the real `render()` and
/// counted what landed on screen. These tests do exactly that, across the full
/// `CardState × CardFlow` matrix from `.allCases` — so a NEW state or a NEW flow
/// that the grid forgets a cell for fails here instead of vanishing in the field.
@MainActor
@Suite("Board render visibility — no card silently vanishes")
struct BoardRenderVisibilityTests {

    private func board() -> BoardView {
        let view = BoardView()
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        return view
    }

    private func card(_ state: CardState, _ flow: CardFlow) -> BoardCard {
        BoardCard(sessionID: "s-\(state.rawValue)-\(flow.rawValue)", projectDir: "~/x",
                  agent: .claude, flow: flow, state: state)
    }

    /// Count `SessionCard` views placed anywhere under the board — the real "did
    /// this card land on the board" question, not the private cell map.
    private func sessionCardCount(_ view: NSView) -> Int {
        (view is SessionCard ? 1 : 0)
            + view.subviews.reduce(0) { $0 + sessionCardCount($1) }
    }

    @Test("every (state, flow) card renders exactly one card — none silently disappears")
    func everyStateAndFlowRendersVisibly() {
        for state in CardState.allCases {
            for flow in CardFlow.allCases {
                let view = board()
                view.render(cards: [card(state, flow)])
                #expect(sessionCardCount(view) == 1,
                    "a \(state.rawValue)/\(flow.rawValue) card must render on the board, not vanish")
            }
        }
    }

    @Test("a full mixed board conserves every card — count in == count out")
    func fullMatrixConservesEveryCard() {
        let cards = CardState.allCases.flatMap { state in
            CardFlow.allCases.map { flow in card(state, flow) }
        }
        let view = board()
        view.render(cards: cards)
        #expect(sessionCardCount(view) == cards.count,
            "\(cards.count) cards in the model must render \(cards.count) cards on the board")
    }
}
