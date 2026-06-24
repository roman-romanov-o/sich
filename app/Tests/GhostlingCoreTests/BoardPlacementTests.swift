import Foundation
import Testing
@testable import GhostlingCore

// The board view-model, ported faithfully from the Python source of truth
// (src/mission_control/board/{card,placement,attention}.py) which is already
// E2E-green. These tests are the logic-level mirror of TC-E2E-001/002 in Swift.

private func card(
    _ id: String,
    _ dir: String,
    agent: CardAgent = .claude,
    flow: CardFlow = .b,
    state: CardState
) -> BoardCard {
    BoardCard(sessionID: id, projectDir: dir, agent: agent, flow: flow, state: state)
}

@Suite("Board placement — cards by state (US-003)")
struct BoardPlacementTests {

    @Test("each state maps to its own column; unknown/stale → unknown column")
    func stateColumnMapping() {
        #expect(BoardColumn(state: .idle) == .idle)
        #expect(BoardColumn(state: .running) == .running)
        #expect(BoardColumn(state: .waitingForInput) == .waitingForInput)
        #expect(BoardColumn(state: .runningTests) == .runningTests)
        #expect(BoardColumn(state: .blocked) == .blocked)
        #expect(BoardColumn(state: .done) == .done)
        #expect(BoardColumn(state: .unknown) == .unknown)
    }

    @Test("one card per session, placed in the correct column (US-003 AC#1)")
    func oneCardPerSessionCorrectColumn() {
        // Mirrors TC-E2E-001: projA running, projB waiting, projC idle.
        let cards = [
            card("projA", "~/proj-a", state: .running),
            card("projB", "~/proj-b", state: .waitingForInput),
            card("projC", "~/proj-c", state: .idle),
        ]
        let placed = placeCards(cards)

        #expect(placed[.running]?.map(\.sessionID) == ["projA"])
        #expect(placed[.waitingForInput]?.map(\.sessionID) == ["projB"])
        #expect(placed[.idle]?.map(\.sessionID) == ["projC"])
        // No duplicates: exactly three cards land across all columns.
        #expect(placed.values.reduce(0) { $0 + $1.count } == 3)
    }

    @Test("every column key is present even when empty (renderer draws all)")
    func everyColumnPresent() {
        let placed = placeCards([])
        for column in BoardColumn.allCases {
            #expect(placed[column] != nil)
            #expect(placed[column]?.isEmpty == true)
        }
    }

    @Test("card carries cmux metadata: dir, agent, flow, state (US-003 AC#2)")
    func cardMetadata() {
        let c = card("projB", "~/proj-b", agent: .claude, flow: .b, state: .waitingForInput)
        #expect(c.projectDir == "~/proj-b")
        #expect(c.agent == .claude)
        #expect(c.agent.displayName == "Claude Code")
        #expect(c.flow == .b)
        #expect(c.state == .waitingForInput)
    }

    @Test("waiting and blocked are merged into one attention group, distinct states")
    func attentionGroupingIsRenderOnly() {
        #expect(BoardColumn.waitingForInput.isAttention)
        #expect(BoardColumn.blocked.isAttention)
        #expect(!BoardColumn.running.isAttention)
        #expect(!BoardColumn.idle.isAttention)
        // The states themselves stay distinct (not collapsed in placement).
        #expect(BoardColumn(state: .waitingForInput) != BoardColumn(state: .blocked))
    }
}

@Suite("Who-needs-me attention signal (US-005)")
struct AttentionSignalTests {

    @Test("count equals waiting + blocked (US-005 AC#1)")
    func countEqualsWaitingPlusBlocked() {
        let cards = [
            card("a", "~/a", state: .waitingForInput),
            card("b", "~/b", state: .blocked),
            card("c", "~/c", state: .running),
            card("d", "~/d", state: .idle),
        ]
        #expect(Attention.count(cards) == 2)
        #expect(Attention.cards(cards).map(\.sessionID) == ["a", "b"])
    }

    @Test("reads exactly 0 when all running/idle — no false alarm (US-005 AC#3)")
    func zeroWhenQuiet() {
        let cards = [
            card("a", "~/a", state: .running),
            card("b", "~/b", state: .idle),
            card("c", "~/c", state: .runningTests),
            card("d", "~/d", state: .done),
        ]
        #expect(Attention.count(cards) == 0)
        #expect(Attention.cards(cards).isEmpty)
    }

    @Test("empty board is quiet (0), not an alarm")
    func emptyBoardQuiet() {
        #expect(Attention.count([]) == 0)
    }
}

@Suite("Board selection / drill-in routing (US-002 / US-005 AC#2)")
struct BoardSelectionTests {

    @Test("focusing a card records it; returning to the board clears it (US-002)")
    func focusAndReturn() {
        let target = card("projB", "~/proj-b", state: .waitingForInput)
        var selection = BoardSelection()
        #expect(selection.focusedCardID == nil)

        selection.focus(target.id)
        #expect(selection.focusedCardID == target.id)

        selection.returnToBoard()
        #expect(selection.focusedCardID == nil)
    }

    @Test("activating attention filters the board to waiting/blocked (US-005 AC#2)")
    func activateAttentionFilters() {
        let cards = [
            card("a", "~/a", state: .waitingForInput),
            card("b", "~/b", state: .blocked),
            card("c", "~/c", state: .running),
        ]
        var selection = BoardSelection()
        selection.activateAttention(cards)

        #expect(selection.attentionFilterActive)
        #expect(selection.visibleCards(from: cards).map(\.sessionID) == ["a", "b"])
    }

    @Test("activating attention with nothing waiting does not engage the filter")
    func activateAttentionQuietNoOp() {
        let cards = [card("c", "~/c", state: .running)]
        var selection = BoardSelection()
        selection.activateAttention(cards)

        #expect(!selection.attentionFilterActive)
        #expect(selection.visibleCards(from: cards).count == 1)
    }

    @Test("clearing the filter shows the full board again")
    func clearFilter() {
        let cards = [
            card("a", "~/a", state: .blocked),
            card("c", "~/c", state: .running),
        ]
        var selection = BoardSelection()
        selection.activateAttention(cards)
        selection.clearAttentionFilter()

        #expect(!selection.attentionFilterActive)
        #expect(selection.visibleCards(from: cards).count == 2)
    }
}
