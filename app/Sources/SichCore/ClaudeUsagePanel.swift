import Foundation

/// Parses the rendered `/usage` panel of Claude Code — the plain-text screen a
/// libghostty ``Terminal`` produces after the hidden probe types `/usage`.
///
/// This is the REAL measured utilization the interactive pool is billed against
/// (the same numbers `claude` shows its user), so the mapped reading is
/// `inferred:false` → the gauge renders it `measured`. The panel also shows
/// per-model rows ("Current week (Fable)") — ignored on purpose: the gauge tracks
/// the two constraints Anthropic enforces account-wide, session (5h rolling) and
/// week (all models), mirroring `UsageEndpointReader.interactiveSource`.
public enum ClaudeUsagePanel {

    /// The two constraints scraped off the panel. Reset dates are best-effort
    /// (nil when the "Resets …" line is missing or unparseable) — the percent is
    /// the load-bearing number.
    public struct Reading: Equatable, Sendable {
        public let sessionUsedPercent: Double
        public let weekUsedPercent: Double
        public let sessionResetsAt: Date?
        public let weekResetsAt: Date?

        public init(sessionUsedPercent: Double, weekUsedPercent: Double,
                    sessionResetsAt: Date?, weekResetsAt: Date?) {
            self.sessionUsedPercent = sessionUsedPercent
            self.weekUsedPercent = weekUsedPercent
            self.sessionResetsAt = sessionResetsAt
            self.weekResetsAt = weekResetsAt
        }
    }

    /// Parse the panel screen. Returns nil unless BOTH section percentages are
    /// present — a partial render keeps the caller polling, and any layout drift
    /// in a future claude version degrades to the estimate, never to a fake zero.
    public static func parse(screen: String, now: Date = Date(),
                             calendar: Calendar = .current) -> Reading? {
        guard let session = section(after: "Current session", in: screen,
                                    now: now, calendar: calendar),
              let week = section(after: "Current week (all models)", in: screen,
                                 now: now, calendar: calendar)
        else { return nil }
        return Reading(sessionUsedPercent: session.percent,
                       weekUsedPercent: week.percent,
                       sessionResetsAt: session.reset,
                       weekResetsAt: week.reset)
    }

    /// Map a parsed panel to the interactive-pool source. Identical binding logic
    /// to `UsageEndpointReader.interactiveSource`: the constraint with LESS
    /// remaining drives the gauge, its reset and refill kind included.
    public static func interactiveSource(
        from reading: Reading, poolPrefix: String = "interactive"
    ) -> QuotaSourceInput {
        let windowBinds = reading.sessionUsedPercent >= reading.weekUsedPercent
        let used = windowBinds ? reading.sessionUsedPercent : reading.weekUsedPercent
        let remaining = max(0.0, min(1.0, 1.0 - used / 100.0))
        return QuotaSourceInput(
            provider: "anthropic", pool: poolPrefix,
            reading: QuotaSourceReading(
                available: true,
                inferred: false,               // scraped off claude's own panel → "measured"
                remainingFraction: remaining,
                reset: windowBinds ? reading.sessionResetsAt : reading.weekResetsAt,
                refillKind: windowBinds ? .rollingWindow : .weekly,
                state: remaining <= 0.0 ? .exhausted : .active
            )
        )
    }

    public static func interactiveDisplaySources(
        from reading: Reading, poolPrefix: String = "interactive"
    ) -> [QuotaSourceInput] {
        [
            splitSource(pool: "\(poolPrefix)_5h",
                        used: reading.sessionUsedPercent,
                        reset: reading.sessionResetsAt,
                        refill: .rollingWindow),
            splitSource(pool: "\(poolPrefix)_weekly",
                        used: reading.weekUsedPercent,
                        reset: reading.weekResetsAt,
                        refill: .weekly),
        ]
    }

    private static func splitSource(
        pool: String, used: Double, reset: Date?, refill: QuotaRefillKind
    ) -> QuotaSourceInput {
        let remaining = max(0.0, min(1.0, 1.0 - used / 100.0))
        return QuotaSourceInput(
            provider: "anthropic", pool: pool,
            reading: QuotaSourceReading(
                available: true,
                inferred: false,
                remainingFraction: remaining,
                reset: reset,
                refillKind: refill,
                state: remaining <= 0.0 ? .exhausted : .active
            )
        )
    }

    // MARK: - Section extraction

    /// The first "NN% used" and "Resets …" after a section title. Sections render
    /// in panel order (session → week (all models) → per-model rows), so
    /// first-match-after-title always belongs to that section.
    private static func section(after title: String, in screen: String,
                                now: Date, calendar: Calendar)
        -> (percent: Double, reset: Date?)?
    {
        guard let titleRange = screen.range(of: title) else { return nil }
        let tail = screen[titleRange.upperBound...]
        guard let match = tail.firstMatch(of: #/(\d+(?:\.\d+)?)\s*%\s*used/#),
              let percent = Double(match.1) else { return nil }
        // Drop the trailing "(Europe/Kiev)" — claude renders resets in local time.
        let reset = tail.firstMatch(of: #/Resets\s+([^\n(]+)/#)
            .flatMap { parseReset(String($0.1), now: now, calendar: calendar) }
        return (percent, reset)
    }

    // MARK: - Reset-time parsing ("4pm", "11:30pm", "Jul 6 at 3am")

    static func parseReset(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let m = text.firstMatch(of:
            #/([A-Za-z]{3,9})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/#
            .ignoresCase()),
            let month = months[String(m.1).lowercased()], let day = Int(m.2), let hour = Int(m.3)
        {
            return monthDayDate(month: month, day: day,
                                hour: hour24(hour, meridiem: m.5.map(String.init)),
                                minute: m.4.flatMap { Int($0) } ?? 0,
                                now: now, calendar: calendar)
        }
        if let m = text.firstMatch(of: #/(\d{1,2})(?::(\d{2}))?\s*(am|pm)/#.ignoresCase()),
           let hour = Int(m.1)
        {
            return timeOnlyDate(hour: hour24(hour, meridiem: String(m.3)),
                                minute: m.2.flatMap { Int($0) } ?? 0,
                                now: now, calendar: calendar)
        }
        return nil
    }

    /// "Jul 6 at 3am" → this year; a date reading far in the past wrapped the
    /// year boundary (panel shown Dec 30, reset Jan 2) → next year.
    private static func monthDayDate(month: Int, day: Int, hour: Int, minute: Int,
                                     now: Date, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year], from: now)
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        guard let candidate = calendar.date(from: comps) else { return nil }
        return candidate < now.addingTimeInterval(-86_400)
            ? calendar.date(byAdding: .year, value: 1, to: candidate)
            : candidate
    }

    /// "4pm" → today at 16:00, or tomorrow if that already passed (a reset is
    /// always in the future).
    private static func timeOnlyDate(hour: Int, minute: Int,
                                     now: Date, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        guard let today = calendar.date(from: comps) else { return nil }
        return today <= now ? calendar.date(byAdding: .day, value: 1, to: today) : today
    }

    private static func hour24(_ hour: Int, meridiem: String?) -> Int {
        switch meridiem?.lowercased() {
        case "am": return hour == 12 ? 0 : hour
        case "pm": return hour == 12 ? 12 : hour + 12
        default: return hour
        }
    }

    /// "jul"/"july" → 7, from the fixed en_US_POSIX symbols (claude renders
    /// English month names regardless of system locale).
    private static let months: [String: Int] = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        var map: [String: Int] = [:]
        for (i, name) in fmt.shortMonthSymbols.enumerated() { map[name.lowercased()] = i + 1 }
        for (i, name) in fmt.monthSymbols.enumerated() { map[name.lowercased()] = i + 1 }
        return map
    }()
}
