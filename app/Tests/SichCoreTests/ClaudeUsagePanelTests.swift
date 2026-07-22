import Foundation
import Testing

@testable import SichCore

/// The `/usage`-panel parser behind the shipped measured quota gauge. Pure text →
/// reading: no pty, no spawn — the fixture is the panel exactly as the libghostty
/// grid rendered it in the live probe capture (claude v2.1.201). The driver
/// (`ClaudeUsageProbe`) is covered by the manual `sich-probe usage` smoke;
/// `spawningEnabled` stays false under `swift test` so nothing here can spawn.
@Suite("Claude /usage panel parse + interactive source mapping")
struct ClaudeUsagePanelTests {

    /// UTC gregorian + a fixed `now` so reset-date math is deterministic.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        DateComponents(calendar: calendar, year: y, month: mo, day: d, hour: h, minute: mi).date!
    }

    /// The panel as rendered in the real capture — including the per-model row
    /// the parser must ignore and the bar glyphs before the percent.
    private func panel(session: Int = 32, week: Int = 28) -> String {
        """
        Settings

         Status   Config   Usage

        Current session
        ████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   \(session)% used
        Resets 4pm (Europe/Kiev)

        Current week (all models)
        ██████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   \(week)% used
        Resets Jul 6 at 3am (Europe/Kiev)

        Current week (Fable)
        ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   17% used
        Resets Jul 6 at 3am (Europe/Kiev)

         Esc to exit
        """
    }

    @Test("real capture parses: both percentages + local reset dates")
    func realCaptureParses() throws {
        let now = date(2026, 7, 4, 10, 0)   // 10am — before the 4pm session reset
        let r = try #require(ClaudeUsagePanel.parse(screen: panel(), now: now, calendar: calendar))
        #expect(r.sessionUsedPercent == 32)
        #expect(r.weekUsedPercent == 28)          // (all models), NOT the 17% Fable row
        #expect(r.sessionResetsAt == date(2026, 7, 4, 16, 0))   // "4pm" today
        #expect(r.weekResetsAt == date(2026, 7, 6, 3, 0))       // "Jul 6 at 3am"
    }

    @Test("session binds (32 ≥ 28): measured, remaining 0.68, rolling window, session reset")
    func sessionBindsMapping() throws {
        let now = date(2026, 7, 4, 10, 0)
        let r = try #require(ClaudeUsagePanel.parse(screen: panel(), now: now, calendar: calendar))
        let src = ClaudeUsagePanel.interactiveSource(from: r)
        #expect(src.provider == "anthropic")
        #expect(src.pool == "interactive")
        #expect(src.reading.inferred == false)    // scraped measurement → gauge shows "measured"
        #expect(abs((src.reading.remainingFraction ?? -1) - 0.68) < 1e-9)
        #expect(src.reading.refillKind == .rollingWindow)
        #expect(src.reading.reset == r.sessionResetsAt)
        #expect(src.reading.state == .active)
    }

    @Test("week binds (10 < 55): remaining 0.45, weekly, week reset")
    func weekBindsMapping() throws {
        let now = date(2026, 7, 4, 10, 0)
        let r = try #require(ClaudeUsagePanel.parse(
            screen: panel(session: 10, week: 55), now: now, calendar: calendar))
        let src = ClaudeUsagePanel.interactiveSource(from: r)
        #expect(abs((src.reading.remainingFraction ?? -1) - 0.45) < 1e-9)
        #expect(src.reading.refillKind == .weekly)
        #expect(src.reading.reset == r.weekResetsAt)
    }

    @Test("100% used → exhausted, remaining 0")
    func exhausted() throws {
        let now = date(2026, 7, 4, 10, 0)
        let r = try #require(ClaudeUsagePanel.parse(
            screen: panel(session: 100, week: 60), now: now, calendar: calendar))
        let src = ClaudeUsagePanel.interactiveSource(from: r)
        #expect(src.reading.remainingFraction == 0.0)
        #expect(src.reading.state == .exhausted)
    }

    @Test("partial render / non-usage screens parse to nil, never a fake reading")
    func partialRenderIsNil() {
        // The main prompt (what the screen shows before /usage is typed).
        let prompt = "Welcome back Roman\n\n> Try \"edit <filepath> to...\"\nshift+tab to cycle"
        #expect(ClaudeUsagePanel.parse(screen: prompt) == nil)
        // Section titles painted but percentages not yet rendered.
        let partial = "Current session\nResets 4pm\n\nCurrent week (all models)\nResets Jul 6 at 3am"
        #expect(ClaudeUsagePanel.parse(screen: partial) == nil)
        // Session rendered, week still missing → keep polling.
        let half = "Current session\n███  32% used\nResets 4pm\n\nCurrent week (all models)"
        #expect(ClaudeUsagePanel.parse(screen: half) == nil)
    }

    @Test("time-only reset already past → tomorrow; 12am/12pm edges")
    func timeOnlyResetRollsToTomorrow() {
        let now = date(2026, 7, 4, 17, 0)   // 5pm — "4pm" already passed today
        #expect(ClaudeUsagePanel.parseReset("4pm", now: now, calendar: calendar)
            == date(2026, 7, 5, 16, 0))
        #expect(ClaudeUsagePanel.parseReset("11:30pm", now: now, calendar: calendar)
            == date(2026, 7, 4, 23, 30))
        #expect(ClaudeUsagePanel.parseReset("12am", now: now, calendar: calendar)
            == date(2026, 7, 5, 0, 0))
        #expect(ClaudeUsagePanel.parseReset("12pm", now: now, calendar: calendar)
            == date(2026, 7, 5, 12, 0))
    }

    @Test("month-day reset wraps the year boundary")
    func monthDayResetWrapsYear() {
        let now = date(2026, 12, 30, 12, 0)
        #expect(ClaudeUsagePanel.parseReset("Jan 2 at 3am", now: now, calendar: calendar)
            == date(2027, 1, 2, 3, 0))
        // …and a same-year date stays in the current year.
        #expect(ClaudeUsagePanel.parseReset("Dec 31 at 11pm", now: now, calendar: calendar)
            == date(2026, 12, 31, 23, 0))
    }

    @Test("unparseable reset text degrades to nil reset, percent still read")
    func unparseableResetIsNil() throws {
        let screen = """
        Current session
        ███  32% used
        Resets soonish

        Current week (all models)
        ███  28% used
        Resets whenever
        """
        let r = try #require(ClaudeUsagePanel.parse(screen: screen))
        #expect(r.sessionUsedPercent == 32)
        #expect(r.sessionResetsAt == nil)
        #expect(r.weekResetsAt == nil)
    }
}
