import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// Checklist 18.08, item 7: the "needs you" aging bar — a hairline along the card's
/// bottom edge that fills and warms with waiting time, so a card waiting 4 minutes
/// is nearly invisible and one waiting 3h35m is loud.
@MainActor
@Suite(.serialized)
struct AgingBarTests {

    private func card(_ state: CardState, updatedAt: Date = .distantPast) -> BoardCard {
        BoardCard(id: UUID(), sessionID: "t", projectDir: "/tmp/proj",
                  agent: .claude, state: state, updatedAt: updatedAt)
    }

    // MARK: - The aging curve (pure functions)

    @Test("4 minutes of waiting is a barely-there sliver; 3h35m is a full bar")
    func agingCurve() {
        #expect(SessionCard.agingFraction(0) == 0)
        let fourMinutes = SessionCard.agingFraction(4 * 60)
        #expect(fourMinutes > 0 && fourMinutes < 0.03,
                "4m must be nearly invisible, got \(fourMinutes)")
        #expect(SessionCard.agingFraction(3 * 3600 + 35 * 60) == 1, "3h35m is loud: full")
        #expect(SessionCard.agingFraction(24 * 3600) == 1, "clamped, never overflows the card")
        #expect(SessionCard.agingFraction(30 * 60) > fourMinutes, "monotonic")
    }

    @Test("the bar's ink warms with age — translucent amber young, solid alert red old")
    func agingInkWarms() {
        let young = SessionCard.agingColor(4 * 60)
        let old = SessionCard.agingColor(4 * 3600)
        #expect(young.alphaComponent < 0.45, "a young bar stays quiet")
        #expect(old.alphaComponent == 1.0, "an old bar is at full strength")
        let alert = BoardTheme.alert.usingColorSpace(.sRGB)!
        let oldRGB = old.usingColorSpace(.sRGB)!
        #expect(abs(oldRGB.redComponent - alert.redComponent) < 0.01,
                "past the 3h mark the ink IS the alert red")
    }

    // MARK: - The card face

    @Test("a waiting card grows the bar; its width tracks the waiting time")
    func waitingCardCarriesTheBar() throws {
        let epoch = Date(timeIntervalSince1970: 1_755_500_000)
        let waited: TimeInterval = 90 * 60   // 1h30m of 3h → half a bar
        let view = SessionCard(
            card: card(.waitingForInput),
            now: { epoch },
            hostState: { _ in .installed },
            waitingSince: { _ in epoch.addingTimeInterval(-waited) })
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        view.layoutSubtreeIfNeeded()

        let bar = try #require(view.agingBarForTesting, "a needs-you card carries the bar")
        let usable: CGFloat = 300 - 12   // 6pt inset each side
        let expected = usable * SessionCard.agingFraction(waited)
        #expect(abs(bar.frame.width - expected) < 0.5,
                "half the wait → half the bar, got \(bar.frame.width) vs \(expected)")
        #expect(bar.frame.minY <= 2.5, "hairline hugs the bottom edge")
    }

    @Test("a working card and an unclocked waiting card stay clean — no bar")
    func calmCardsStayClean() {
        let working = SessionCard(
            card: card(.running), hostState: { _ in .installed },
            waitingSince: { _ in Date(timeIntervalSince1970: 0) })
        #expect(working.agingBarForTesting == nil, "only needs-attention states age")

        let unclocked = SessionCard(
            card: card(.waitingForInput), hostState: { _ in .installed },
            waitingSince: { _ in nil })
        #expect(unclocked.agingBarForTesting == nil, "no waiting-since, nothing to age")
    }

    // MARK: - The clock

    @Test("the clock starts on entering needs-attention, holds, and clears on leaving")
    func clockEdges() {
        let clock = AttentionClock()
        let t0 = Date(timeIntervalSince1970: 1_755_500_000)
        let waiting = card(.waitingForInput)

        clock.note(waiting, at: t0)
        #expect(clock.waitingSince(waiting.id) == t0)

        clock.note(waiting, at: t0.addingTimeInterval(600))
        #expect(clock.waitingSince(waiting.id) == t0, "re-observing the same wait does not reset it")

        clock.note(waiting.with(state: .running), at: t0.addingTimeInterval(900))
        #expect(clock.waitingSince(waiting.id) == nil, "leaving needs-attention stops the clock")
    }

    @Test("a hook-observed card seeds the clock from its last observation time")
    func clockSeedsFromObservation() {
        let clock = AttentionClock()
        let observed = Date(timeIntervalSince1970: 1_755_400_000)
        let waiting = card(.waitingForInput, updatedAt: observed)
        clock.note(waiting, at: observed.addingTimeInterval(1800))
        #expect(clock.waitingSince(waiting.id) == observed,
                "the card was already waiting before we first swept it")
    }

    // MARK: - E2E through the board

    @Test("moving a card into NEEDS YOU starts its clock and renders the bar; leaving clears both")
    func boardFeedsTheClock() throws {
        let seed = BoardSeed(sessionID: "aging-e2e", projectDir: "/tmp/aging-proj",
                             agent: .claude, state: .running, scrollback: "")
        let shell = BoardShell(seeds: [seed])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        let cardID = try #require(shell.cards.first?.id)

        shell.move(cardID: cardID, to: .waitingForInput)

        #expect(AttentionClock.shared.waitingSince(cardID) != nil,
                "the render sweep feeds the clock")
        let cell = try #require(shell.boardView.cellForTesting(.needsYou))
        let face = try #require(
            cell.arrangedSubviews.compactMap { $0 as? SessionCard }.first { $0.card.id == cardID })
        #expect(face.agingBarForTesting != nil, "the rendered NEEDS YOU card carries the bar")

        shell.move(cardID: cardID, to: .running)
        #expect(AttentionClock.shared.waitingSince(cardID) == nil,
                "back to work — the wait is over, the clock clears")
    }
}
