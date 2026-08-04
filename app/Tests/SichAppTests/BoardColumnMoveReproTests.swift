import AppKit
import SichCore
import Testing

@testable import SichApp

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

    /// The "app becomes slow with many tasks" fix: a live state flap of one active
    /// agent must not tear down and rebuild the whole DONE/QUEUE ledger — each card
    /// view carries labels, layers, tracking areas, and a timer, so rebuilding all
    /// of them on every flap scaled the cost of ONE agent's activity by the TOTAL
    /// card count. Untouched columns keep their view instances; the changed column
    /// still repaints (the live-column-move contract above is unaffected).
    @Test("a state flap in one column leaves other columns' views untouched")
    func untouchedColumnsReuseTheirViews() throws {
        let view = board()
        let done = BoardCard(id: UUID(), sessionID: "d", projectDir: "~/x",
                             agent: .claude, flow: .b, state: .done)
        let live = BoardCard(id: UUID(), sessionID: "r", projectDir: "~/x",
                             agent: .claude, flow: .b, state: .running)
        view.render(cards: [done, live])
        let doneViewBefore = try #require(sessionCards(view, in: .done).first)

        view.render(cards: [done, live.with(state: .runningTests)])
        let doneViewAfter = try #require(sessionCards(view, in: .done).first)
        #expect(doneViewBefore === doneViewAfter,
                "an unchanged DONE column must keep its existing card view")
        let workingView = try #require(sessionCards(view, in: .working).first)
        #expect(workingView.card.state == .runningTests,
                "the changed WORKING column must repaint to the new state")
    }

    private func sessionCards(_ view: BoardView, in group: BoardView.ColumnGroup) -> [SessionCard] {
        view.cellForTesting(group)?.arrangedSubviews.compactMap { $0 as? SessionCard } ?? []
    }
}
