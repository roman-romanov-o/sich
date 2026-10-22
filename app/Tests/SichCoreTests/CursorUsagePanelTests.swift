import Foundation
import Testing
@testable import SichCore

/// `CursorUsagePanel` against the panel exactly as the hidden probe captured it
/// (2026-08-25, `agent --trust` → `/usage`), so a layout drift shows up here first.
struct CursorUsagePanelTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Kiev")!
        return cal
    }

    private func panel(included: Int = 1) -> String {
        """
        ────────────────────────────────────────────────────────────────────────────────────────────────────
         Usage • Team                                                                       Resets Sep 24
         Monthly plan and on-demand usage
         Category        Current             Usage
         Included        \(included)% used             █░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
           Auto          1% used             █░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
           API           0% used             ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
         On-Demand       $0                  ————————————————————————————————————————————————————————————
         No personal limit
         View in dashboard: cursor.com/dashboard?tab=usage
         Esc to close
        """
    }

    @Test func parsesIncludedPercentAndMonthlyReset() throws {
        let now = DateComponents(calendar: calendar, year: 2026, month: 8, day: 25, hour: 12).date!
        let reading = try #require(CursorUsagePanel.parse(screen: panel(included: 37), now: now, calendar: calendar))
        #expect(reading.includedUsedPercent == 37)
        #expect(reading.resetsAt == DateComponents(calendar: calendar, year: 2026, month: 9, day: 24).date!)
    }

    @Test func resetAcrossNewYearRollsForward() throws {
        let now = DateComponents(calendar: calendar, year: 2026, month: 12, day: 30).date!
        let screen = panel().replacingOccurrences(of: "Resets Sep 24", with: "Resets Jan 2")
        let reading = try #require(CursorUsagePanel.parse(screen: screen, now: now, calendar: calendar))
        #expect(reading.resetsAt == DateComponents(calendar: calendar, year: 2027, month: 1, day: 2).date!)
    }

    @Test func loadingScreenIsNotAReading() {
        #expect(CursorUsagePanel.parse(screen: "  Loading usage data...\n  Composer 2.5 Fast") == nil)
    }

    @Test func mapsToAMeasuredMonthlyCursorGauge() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let source = CursorUsagePanel.source(from: .init(includedUsedPercent: 37, resetsAt: reset))
        #expect(source.provider == "cursor" && source.pool == "cursor")
        #expect(source.reading.inferred == false)
        #expect(source.reading.remainingFraction == 0.63)
        #expect(source.reading.refillKind == .monthlyHardStop)
        #expect(source.reading.reset == reset)
        let gauge = QuotaProjection.gauge(for: source)
        #expect(gauge.confidence == .measured)
        #expect(gauge.state == .active)
        #expect(QuotaProjection.gauge(for: CursorUsagePanel.source(from: .init(includedUsedPercent: 100, resetsAt: nil))).state == .exhausted)
    }
}
