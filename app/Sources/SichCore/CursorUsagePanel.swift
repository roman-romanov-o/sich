import Foundation

/// Parses the rendered `/usage` panel of the Cursor CLI (`agent`) — the plain-text
/// screen a libghostty ``Terminal`` produces after the hidden probe types `/usage`:
///
///     Usage • Team                                   Resets Sep 24
///     Monthly plan and on-demand usage
///     Category        Current             Usage
///     Included        1% used             █░░░░…
///       Auto          1% used             …
///       API           0% used             …
///     On-Demand       $0                  ————…
///
/// Cursor bills one monthly plan, so the gauge tracks the `Included` row (the
/// account-wide number); the Auto/API sub-rows and on-demand spend are ignored.
public enum CursorUsagePanel {
    public struct Reading: Equatable, Sendable {
        public let includedUsedPercent: Double
        public let resetsAt: Date?

        public init(includedUsedPercent: Double, resetsAt: Date?) {
            self.includedUsedPercent = includedUsedPercent
            self.resetsAt = resetsAt
        }
    }

    /// Nil unless the `Included … % used` row is present — a partial render keeps
    /// the caller polling, and layout drift degrades to `unknown`, never a fake zero.
    public static func parse(screen: String, now: Date = Date(),
                             calendar: Calendar = .current) -> Reading? {
        guard let match = screen.firstMatch(of: #/Included\s+(\d+(?:\.\d+)?)\s*%\s*used/#),
              let percent = Double(match.1) else { return nil }
        let reset = screen.firstMatch(of: #/Resets\s+([A-Za-z]{3,9})\s+(\d{1,2})/#)
            .flatMap { resetDate(month: String($0.1), day: Int($0.2), now: now, calendar: calendar) }
        return Reading(includedUsedPercent: percent, resetsAt: reset)
    }

    /// The measured cursor source: `inferred:false` → the gauge renders `measured`.
    public static func source(from reading: Reading) -> QuotaSourceInput {
        let remaining = max(0.0, min(1.0, 1.0 - reading.includedUsedPercent / 100.0))
        return QuotaSourceInput(
            provider: "cursor", pool: "cursor",
            reading: QuotaSourceReading(
                available: true,
                inferred: false,
                remainingFraction: remaining,
                reset: reading.resetsAt,
                refillKind: .monthlyHardStop,
                state: remaining <= 0.0 ? .exhausted : .active
            )
        )
    }

    /// "Sep 24" → that day at local midnight, this year; a reading far in the past
    /// wrapped the year boundary (panel shown Dec 30, reset Jan 2) → next year.
    private static func resetDate(month: String, day: Int?, now: Date, calendar: Calendar) -> Date? {
        guard let day, let monthIndex = months[month.lowercased()] else { return nil }
        var comps = calendar.dateComponents([.year], from: now)
        comps.month = monthIndex
        comps.day = day
        guard let candidate = calendar.date(from: comps) else { return nil }
        return candidate < now.addingTimeInterval(-86_400)
            ? calendar.date(byAdding: .year, value: 1, to: candidate)
            : candidate
    }

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]
}

/// The Cursor probe: a hidden `agent --trust` (no folder dialog), its `/usage`
/// panel read by ``CursorUsagePanel``.
public enum CursorUsageProbe {
    public static let spec = TUIUsageProbeSpec<CursorUsagePanel.Reading>(
        launch: "agent --trust",
        readyMarkers: ["Plan, search, build anything"],
        trustPrompt: nil,
        parse: { CursorUsagePanel.parse(screen: $0) }
    )

    public static let shared = TUIUsageProbe(spec: spec)

    public static func scrape(deadline: TimeInterval = 75) -> CursorUsagePanel.Reading? {
        TUIUsageProbe.scrape(spec: spec, deadline: deadline)
    }
}
