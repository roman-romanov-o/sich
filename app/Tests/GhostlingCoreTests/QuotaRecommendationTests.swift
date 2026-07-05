import Foundation
import Testing

@testable import GhostlingCore

/// The one runnable check behind `QuotaAdvisor`'s routing ladder (ponytail: branchy
/// policy gets one test). Covers all four directives — the panel's headline is only
/// as honest as this. Builds gauges directly (the advisor reads gauges, not sources).
@Suite("Quota advisor — pool routing (US-006 recommendation)")
struct QuotaRecommendationTests {

    private func anthropic(_ pool: String, _ state: QuotaPoolState, _ fraction: Double?) -> QuotaGauge {
        QuotaGauge(provider: "anthropic", pool: pool, state: state,
                   confidence: .measured, remainingFraction: fraction)
    }

    @Test("interactive healthy → launch interactively")
    func launchInteractive() {
        let rec = QuotaAdvisor.recommend(from: [
            anthropic("interactive", .active, 0.55),
            anthropic("agent_sdk_credit", .active, 0.60),
        ])
        #expect(rec.action == .launchInteractive)
        #expect(rec.detail.contains("55%"))
    }

    @Test("interactive low but SDK healthy → route via saha run")
    func routeToSDK() {
        let rec = QuotaAdvisor.recommend(from: [
            anthropic("interactive", .active, 0.10),
            anthropic("agent_sdk_credit", .active, 0.70),
        ])
        #expect(rec.action == .routeToSDK)
        #expect(rec.detail.contains("70%"))
    }

    @Test("both pools low → hold")
    func holdWhenBothLow() {
        let rec = QuotaAdvisor.recommend(from: [
            anthropic("interactive", .exhausted, nil),
            anthropic("agent_sdk_credit", .active, 0.05),
        ])
        #expect(rec.action == .hold)
    }

    @Test("interactive unknown → measuring (no guess)")
    func measuringWhenUnknown() {
        let rec = QuotaAdvisor.recommend(from: [
            anthropic("interactive", .unknown, nil),
            anthropic("agent_sdk_credit", .unknown, nil),
        ])
        #expect(rec.action == .measuring)
    }
}
