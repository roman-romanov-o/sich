import AppKit
import SichCore
import Testing
@testable import SichApp

/// A card that changes lane drops in (fade + short drop) instead of teleporting;
/// everything that did not move — and the whole first render — stays still.
@MainActor
@Suite(.serialized)
struct CardArrivalTests {

    @Test("only a card new to its lane animates in; the first render and unmoved cards stay still")
    func onlyMovedCardsAnimate() throws {
        let view = BoardView(
            frame: NSRect(x: 0, y: 0, width: 1400, height: 800),
            defaults: try #require(UserDefaults(suiteName: "card-arrival-\(UUID())")))
        let mover = card("mover", .running)
        let stayer = card("stayer", .running)

        view.render(cards: [mover, stayer])
        #expect(arrival(of: mover.id, in: view, .working) == false, "launch render must not animate")

        view.render(cards: [mover.with(state: .waitingForInput), stayer])
        #expect(arrival(of: mover.id, in: view, .needsYou) == true)
        // WORKING was re-rendered (it lost a card) but the card left in it did not move.
        #expect(arrival(of: stayer.id, in: view, .working) == false)
    }

    private func card(_ id: String, _ state: CardState) -> BoardCard {
        BoardCard(sessionID: id, title: id, projectDir: "/tmp/\(id)",
                  agent: .claude, flow: .b, state: state)
    }

    private func arrival(of id: UUID, in view: BoardView, _ group: BoardView.ColumnGroup) -> Bool? {
        let cell = view.cellForTesting(group)
        let card = cell?.arrangedSubviews.compactMap { $0 as? SessionCard }.first { $0.card.id == id }
        return card.map { $0.layer?.animation(forKey: "arrival-fade") != nil }
    }
}
