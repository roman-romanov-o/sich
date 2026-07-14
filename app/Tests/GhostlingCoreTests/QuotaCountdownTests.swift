import Foundation
import Testing

@testable import GhostlingCore

/// The reset-countdown arithmetic behind the quota panel's highlighted "time left"
/// line. All cases are anchored to a fixed `now` so they're deterministic (no
/// wall-clock), the same way the encoder tests pin exact bytes.
@Suite("Quota reset countdown")
struct QuotaCountdownTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ahead(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    @Test("elapsed / imminent resets read as 'now'")
    func pastIsNow() {
        #expect(QuotaCountdown.timeLeft(to: ahead(-60), from: now) == "now")
        #expect(QuotaCountdown.timeLeft(to: now, from: now) == "now")
    }

    @Test("sub-hour resets show whole minutes", arguments: [
        (30, "1m"),            // rounds up so a live reset never flashes "now"
        (840, "14m"),          // 14m
        (3540, "59m"),         // 59m
    ] as [(TimeInterval, String)])
    func minutes(_ seconds: TimeInterval, _ expected: String) {
        #expect(QuotaCountdown.timeLeft(to: ahead(seconds), from: now) == expected)
    }

    @Test("hour-scale resets roll up to h+m, dropping a zero minute", arguments: [
        (3600, "1h"),          // 1h
        (8040, "2h 14m"),      // 2h 14m
        (10800, "3h"),         // 3h
    ] as [(TimeInterval, String)])
    func hours(_ seconds: TimeInterval, _ expected: String) {
        #expect(QuotaCountdown.timeLeft(to: ahead(seconds), from: now) == expected)
    }

    @Test("weekly-scale resets roll up to d+h", arguments: [
        (86400, "1d"),         // 1d
        (273600, "3d 4h"),     // 3d 4h
    ] as [(TimeInterval, String)])
    func days(_ seconds: TimeInterval, _ expected: String) {
        #expect(QuotaCountdown.timeLeft(to: ahead(seconds), from: now) == expected)
    }

    @Test("urgency escalates as the reset nears")
    func urgencyBuckets() {
        #expect(QuotaCountdown.urgency(to: ahead(2 * 60), from: now) == .imminent)
        #expect(QuotaCountdown.urgency(to: ahead(20 * 60), from: now) == .soon)
        #expect(QuotaCountdown.urgency(to: ahead(3 * 3600), from: now) == .distant)
    }
}
