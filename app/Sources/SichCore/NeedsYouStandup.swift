import Foundation

/// Rule 1 (``docs/OPERATING-RULES.md``): stale NEEDS YOU detection — cards waiting
/// too long without an explicit deferral should surface standup, not silently age.
public enum NeedsYouStandup {
    /// How long a needs-attention card may wait before the app treats it as stale.
    public static let staleAfter: TimeInterval = 8 * 3600

    /// Default deferral: start of the next local calendar day (operator rule: “until tomorrow”).
    public static func defaultDeferUntil(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86400)
    }

    /// True when the card has waited long enough that Rule 1 applies.
    public static func isStale(
        waitingSince: Date,
        now: Date = Date(),
        deferredUntil: Date? = nil
    ) -> Bool {
        if let deferredUntil, now < deferredUntil { return false }
        return now.timeIntervalSince(waitingSince) >= staleAfter
    }

    /// Cards in needs-attention states, oldest stale first.
    public static func staleCards(
        among cards: [BoardCard],
        waitingSince: (UUID) -> Date?,
        deferredUntil: (UUID) -> Date?,
        now: Date = Date()
    ) -> [BoardCard] {
        cards
            .filter { card in
                guard card.state.needsAttention,
                      let since = waitingSince(card.id) else { return false }
                return isStale(
                    waitingSince: since, now: now,
                    deferredUntil: deferredUntil(card.id))
            }
            .sorted { lhs, rhs in
                let l = waitingSince(lhs.id) ?? .distantFuture
                let r = waitingSince(rhs.id) ?? .distantFuture
                return l < r
            }
    }
}
