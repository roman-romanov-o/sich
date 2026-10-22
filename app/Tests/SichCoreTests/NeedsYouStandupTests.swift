import Foundation
import SichCore
import Testing

@Suite("Rule 1 — NEEDS YOU standup staleness")
struct NeedsYouStandupTests {

    @Test("eight hours waiting is stale; deferral suppresses until it expires")
    func staleThresholdAndDefer() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let since = now.addingTimeInterval(-NeedsYouStandup.staleAfter - 60)
        #expect(NeedsYouStandup.isStale(waitingSince: since, now: now))

        let deferUntil = now.addingTimeInterval(3600)
        #expect(!NeedsYouStandup.isStale(
            waitingSince: since, now: now, deferredUntil: deferUntil))

        let afterDefer = deferUntil.addingTimeInterval(1)
        #expect(NeedsYouStandup.isStale(
            waitingSince: since, now: afterDefer, deferredUntil: deferUntil))
    }

    @Test("default defer lands on the next local midnight")
    func defaultDeferUntilTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let until = NeedsYouStandup.defaultDeferUntil(from: now, calendar: calendar)
        let start = calendar.startOfDay(for: now)
        let expected = calendar.date(byAdding: .day, value: 1, to: start)!
        #expect(until == expected)
    }

    @Test("stale cards sort oldest-first")
    func staleOrdering() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = UUID()
        let young = UUID()
        let cards = [
            BoardCard(id: young, sessionID: "y", projectDir: "/y",
                      agent: .claude, flow: .b, state: .waitingForInput),
            BoardCard(id: old, sessionID: "o", projectDir: "/o",
                      agent: .claude, flow: .b, state: .waitingForInput),
        ]
        let since: [UUID: Date] = [
            old: now.addingTimeInterval(-20 * 3600),
            young: now.addingTimeInterval(-9 * 3600),
        ]
        let stale = NeedsYouStandup.staleCards(
            among: cards,
            waitingSince: { since[$0] },
            deferredUntil: { _ in nil },
            now: now
        )
        #expect(stale.map(\.id) == [old, young])
    }
}
