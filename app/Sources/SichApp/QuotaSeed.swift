import Foundation
import SichCore

/// Representative four-pool fixtures for the quota panel — the recorded usage
/// signals the screenshot harness and tests stub in (the suite never hits a
/// provider endpoint or spends quota to read it). Each is a ``QuotaSourceInput``
/// that the ``QuotaProjection`` turns into a gauge, so the seed exercises the same
/// projection rules the Python aggregator enforces.
public enum QuotaSeed {
    /// The screenshot fixture for `sich-quota`: the four-gauge HELM cluster.
    /// - interactive: estimated (window math), partly inferred — carries the cue;
    /// - Agent SDK credit: measured, precise — NOT down-rated;
    /// - Codex: measured, present;
    /// - Gemini: absent → unknown / not tracked (not implied free).
    public static var demo: [QuotaSourceInput] {
        [
            interactive(remainingFraction: 0.55, reset: hoursFromNow(1.2)),
            agentSDKCredit(remainingFraction: 0.60, reset: daysFromNow(12)),
            codex(remainingFraction: 0.40, reset: hoursFromNow(20)),
            geminiAbsent(),
        ]
    }

    /// The honest pre-poll state shown on the real launch path: every pool
    /// unavailable → `unknown` (never 0, never a fabricated 100%). The live poller
    /// swaps in real readings on its first success — so the panel opens admitting it
    /// hasn't measured yet rather than displaying invented numbers (the "pool quota
    /// is mock" complaint). The two Anthropic pools stay separate, never netted.
    public static var connecting: [QuotaSourceInput] {
        [
            unavailable(provider: "anthropic", pool: "interactive"),
            unavailable(provider: "anthropic", pool: "agent_sdk_credit"),
            unavailable(provider: "codex", pool: "codex"),
            unavailable(provider: "gemini", pool: "gemini"),
        ]
    }

    private static func unavailable(provider: String, pool: String) -> QuotaSourceInput {
        QuotaSourceInput(provider: provider, pool: pool,
                         reading: QuotaSourceReading(available: false))
    }

    // MARK: - Source builders (the labels the projection/title rendering keys on)

    public static func interactive(
        remainingFraction: Double,
        inferred: Bool = true,
        state: QuotaPoolState = .active,
        reset: Date?
    ) -> QuotaSourceInput {
        QuotaSourceInput(
            provider: "anthropic", pool: "interactive",
            reading: QuotaSourceReading(
                inferred: inferred,
                remainingFraction: remainingFraction,
                reset: reset,
                refillKind: .rollingWindow,
                state: state
            )
        )
    }

    public static func agentSDKCredit(
        remainingFraction: Double,
        state: QuotaPoolState = .active,
        reset: Date?
    ) -> QuotaSourceInput {
        QuotaSourceInput(
            provider: "anthropic", pool: "agent_sdk_credit",
            reading: QuotaSourceReading(
                inferred: false,
                remainingFraction: remainingFraction,
                reset: reset,
                refillKind: .monthlyHardStop,
                state: state
            )
        )
    }

    public static func codex(remainingFraction: Double, reset: Date?) -> QuotaSourceInput {
        QuotaSourceInput(
            provider: "codex", pool: "codex",
            reading: QuotaSourceReading(
                inferred: false,
                remainingFraction: remainingFraction,
                reset: reset,
                refillKind: .weekly,
                state: .active
            )
        )
    }

    /// Gemini with no usable signal this cycle → unavailable → unknown gauge.
    public static func geminiAbsent() -> QuotaSourceInput {
        QuotaSourceInput(
            provider: "gemini", pool: "gemini",
            reading: QuotaSourceReading(available: false)
        )
    }

    static func hoursFromNow(_ hours: Double) -> Date {
        Date().addingTimeInterval(hours * 3600)
    }

    static func daysFromNow(_ days: Double) -> Date {
        Date().addingTimeInterval(days * 86_400)
    }
}
