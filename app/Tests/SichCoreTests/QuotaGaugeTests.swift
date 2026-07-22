import Foundation
import Testing

@testable import SichCore

/// Projection tests for `QuotaProjection` — the Swift mirror of `quota/aggregator.py`.
/// These pin the four invariants the Python aggregator enforces (TC-INT-101..104),
/// so the value-type core stays faithful before the panel renders it: one gauge per
/// source in order, no cross-pool netting, unavailable → unknown (not 0/100%),
/// inferred → estimated.
@Suite("Quota projection (mirror of aggregator.py — US-006)")
struct QuotaGaugeTests {

    private func interactive(inferred: Bool, fraction: Double) -> QuotaSourceInput {
        QuotaSourceInput(
            provider: "anthropic", pool: "interactive",
            reading: QuotaSourceReading(
                inferred: inferred, remainingFraction: fraction,
                reset: Date(timeIntervalSinceNow: 4200), refillKind: .rollingWindow
            )
        )
    }

    private func agentSDK(fraction: Double, state: QuotaPoolState = .active) -> QuotaSourceInput {
        QuotaSourceInput(
            provider: "anthropic", pool: "agent_sdk_credit",
            reading: QuotaSourceReading(
                inferred: false, remainingFraction: fraction,
                reset: Date(timeIntervalSinceNow: 1_036_800), refillKind: .monthlyHardStop,
                state: state
            )
        )
    }

    @Test("one gauge per source, in source order — pools never netted (TC-INT-101)")
    func independentGaugesInOrder() {
        let gauges = QuotaProjection.gauges(from: [
            interactive(inferred: true, fraction: 0.60),
            agentSDK(fraction: 0.60),
        ])
        #expect(gauges.count == 2)
        #expect(gauges[0].pool == "interactive")
        #expect(gauges[1].pool == "agent_sdk_credit")
        // Each keeps its own remaining — no arithmetic combined them.
        #expect(gauges[0].remainingFraction == 0.60)
        #expect(gauges[1].remainingFraction == 0.60)
    }

    @Test("an unavailable source → unknown with NO remaining (not 0, not 100% — TC-INT-103)")
    func unavailableIsUnknownNotZero() {
        let gauge = QuotaProjection.gauge(for: QuotaSourceInput(
            provider: "gemini", pool: "gemini",
            reading: QuotaSourceReading(available: false)
        ))
        #expect(gauge.state == .unknown)
        #expect(gauge.remainingFraction == nil)
        #expect(gauge.remainingAmount == nil)
    }

    @Test("inferred → estimated; measured → measured (TC-INT-102 / AC#3)")
    func confidenceFollowsInferredFlag() {
        let estimated = QuotaProjection.gauge(for: interactive(inferred: true, fraction: 0.4))
        let measured = QuotaProjection.gauge(for: agentSDK(fraction: 0.6))
        #expect(estimated.confidence == .estimated)
        #expect(measured.confidence == .measured)
    }

    @Test("fallback is derived from refill kind — hard-stop vs window/weekly (TC-INT-104)")
    func fallbackFromRefillKind() {
        let sdk = QuotaProjection.gauge(for: agentSDK(fraction: 0.0, state: .exhausted))
        let win = QuotaProjection.gauge(for: interactive(inferred: true, fraction: 0.0))
        #expect(sdk.fallback == .none)            // monthly hard-stop, no fallback
        #expect(win.fallback == .windowReset)     // interactive recovers on window
    }
}
