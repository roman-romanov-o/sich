import AppKit
import GhostlingCore
import Testing

@testable import GhostlingApp

/// Repro for the operator report: "when claude is working, the task card stays in
/// the same column". Drives the REAL v5 `BoardView.render` twice — idle then
/// running — and asserts the card physically moved from the QUEUE column's cell to
/// the WORKING column's cell.
@MainActor
@Suite("Board column move — card follows its state across renders")
struct BoardColumnMoveReproTests {

    private func board() -> BoardView {
        let view = BoardView()
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The ColumnGroup whose cell currently holds the (single) SessionCard.
    private func groupHoldingCard(_ view: BoardView) -> BoardView.ColumnGroup? {
        for group in BoardView.ColumnGroup.allCases {
            if let cell = view.cellForTesting(group),
               cell.arrangedSubviews.contains(where: { $0 is SessionCard }) {
                return group
            }
        }
        return nil
    }

    @Test("idle → running re-render moves the card QUEUE → WORKING")
    func stateChangeMovesColumn() {
        let view = board()
        let id = UUID()
        let idle = BoardCard(id: id, sessionID: "t1", projectDir: "~/x",
                             agent: .claude, flow: .b, state: .idle)
        view.render(cards: [idle])
        #expect(groupHoldingCard(view) == .queue)

        let running = BoardCard(id: id, sessionID: "t1", projectDir: "~/x",
                                agent: .claude, flow: .b, state: .running)
        view.render(cards: [running])
        #expect(groupHoldingCard(view) == .working)
    }

    @Test("columns read like classic kanban: QUEUE → WORKING → NEEDS YOU → DONE")
    func classicKanbanColumnOrder() {
        #expect(BoardView.ColumnGroup.allCases == [.queue, .working, .needsYou, .done])
    }
}
