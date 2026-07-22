import Foundation

/// Pure "time left until the limit resets" formatting — the machine-testable core
/// behind the quota panel's highlighted reset countdown. Kept AppKit-free so the
/// arithmetic (minutes → "2h 14m", a weekly window → "3d 4h") is unit-testable
/// without a window, exactly like ``KeyEncoder`` sits behind the terminal surface.
public enum QuotaCountdown {
    /// Compact "how long until `reset`" from `now`. Rolls up to the two most
    /// significant non-zero units so a glance reads cleanly:
    /// `"now"` (already elapsed), `"14m"`, `"2h 14m"`, `"3h"`, `"3d 4h"`.
    public static func timeLeft(to reset: Date, from now: Date) -> String {
        let seconds = Int(reset.timeIntervalSince(now).rounded())
        guard seconds > 0 else { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        if hours < 24 { return unitPair(hours, minutes % 60, "h", "m") }
        return unitPair(hours / 24, hours % 24, "d", "h")
    }

    /// `"3h"` when the smaller unit is zero, else `"3h 4m"` — no `"3h 0m"` noise.
    private static func unitPair(_ big: Int, _ small: Int, _ bigUnit: String, _ smallUnit: String) -> String {
        small == 0 ? "\(big)\(bigUnit)" : "\(big)\(bigUnit) \(small)\(smallUnit)"
    }

    /// How urgent the reset is, so the panel can colour it. `.imminent` (< 5 min)
    /// and `.soon` (< 30 min) earn an attention colour; a distant reset stays dim.
    public enum Urgency: Sendable { case imminent, soon, distant }

    public static func urgency(to reset: Date, from now: Date) -> Urgency {
        let minutes = reset.timeIntervalSince(now) / 60
        if minutes < 5 { return .imminent }
        if minutes < 30 { return .soon }
        return .distant
    }
}
