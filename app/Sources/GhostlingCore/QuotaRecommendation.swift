import Foundation

/// A pool-routing directive derived from the live gauges — the capacity panel's
/// *headline*. US-006's "capacity brain leads with a recommendation, not a passive
/// meter": instead of making the operator read four bars and decide, the advisor
/// reads the two Anthropic pools and says where the NEXT launch should go.
///
/// ponytail: a four-branch heuristic over the two Anthropic pools only — enough to
/// turn the panel from a meter into a recommendation. The full US-007/US-009
/// allocator (pick a backlog task, emit the literal `saha run <task>` command,
/// weigh Codex/Gemini as overflow) upgrades `QuotaAdvisor.recommend` in place; the
/// `action`/`headline`/`detail` shape is the stable seam the panel renders.
public struct QuotaRecommendation: Sendable, Equatable {
    /// Drives the band's accent colour and intent. Order = the routing ladder:
    /// prefer the human window, fall back to SDK credit, hold if both are spent,
    /// admit when we simply haven't measured yet.
    public enum Action: String, Sendable, Equatable {
        case launchInteractive
        case routeToSDK
        case hold
        case measuring
    }

    public let action: Action
    /// The one-line directive (e.g. "→ Safe to launch interactively").
    public let headline: String
    /// The supporting "why", with the concrete numbers it routed on.
    public let detail: String

    public init(action: Action, headline: String, detail: String) {
        self.action = action
        self.headline = headline
        self.detail = detail
    }
}

/// Turns the on-screen gauges into a ``QuotaRecommendation``. Pure (no UI, no
/// I/O) so the routing policy is unit-testable in isolation, exactly like
/// `QuotaProjection`.
public enum QuotaAdvisor {
    /// Below this remaining fraction a pool is "low" — don't route fresh heavy
    /// work to it. ponytail: a single flat threshold; make it task-size-aware when
    /// the US-007 allocator knows the cost of the task it's routing.
    static let lowFraction = 0.25

    /// Recommend where the next launch should go, reading the two Anthropic pools.
    /// The interactive window is preferred (it refills); SDK credit is the
    /// fallback (a monthly hard-stop you spend down). Never nets the two — it reads
    /// each independently and routes, honouring the same two-pool invariant the
    /// projection enforces.
    public static func recommend(from gauges: [QuotaGauge]) -> QuotaRecommendation {
        let interactive = pool(gauges, "interactive")
        let sdk = pool(gauges, "agent_sdk_credit")

        // Can't route on a pool we haven't measured — admit it rather than guess.
        guard let interactive, interactive.state != .unknown else {
            return .init(action: .measuring, headline: "Measuring capacity…",
                         detail: "waiting on the first interactive-window reading")
        }

        if healthy(interactive) { return launchInteractive(interactive, sdk) }
        if let sdk, healthy(sdk) { return routeToSDK(interactive, sdk) }
        return hold(interactive)
    }

    // MARK: - Branches

    private static func launchInteractive(_ interactive: QuotaGauge, _ sdk: QuotaGauge?) -> QuotaRecommendation {
        var detail = "interactive window has \(pct(interactive)) headroom — open a session or run /saha:execute"
        if let sdk, sdk.state == .active, let s = sdk.remainingFraction {
            detail += " · SDK credit \(pct(s)) in reserve"
        }
        return .init(action: .launchInteractive, headline: "→ Safe to launch interactively", detail: detail)
    }

    private static func routeToSDK(_ interactive: QuotaGauge, _ sdk: QuotaGauge) -> QuotaRecommendation {
        let why = interactive.state == .exhausted ? "interactive window exhausted"
                                                  : "interactive low (\(pct(interactive)))"
        return .init(action: .routeToSDK, headline: "→ Route the next launch via `saha run`",
                     detail: "\(why) — spend Agent SDK credit (\(pct(sdk))), preserve your window")
    }

    private static func hold(_ interactive: QuotaGauge) -> QuotaRecommendation {
        let what = interactive.state == .exhausted ? "both Anthropic pools spent" : "both Anthropic pools low"
        return .init(action: .hold, headline: "⏸ Hold heavy Anthropic work",
                     detail: "\(what) — let the rolling window refill before launching")
    }

    // MARK: - Helpers

    private static func pool(_ gauges: [QuotaGauge], _ name: String) -> QuotaGauge? {
        gauges.first {
            $0.provider.lowercased() == "anthropic"
                && $0.pool.lowercased().replacingOccurrences(of: "-", with: "_") == name
        }
    }

    /// Active with a measured/inferred fraction at or above the low threshold.
    private static func healthy(_ gauge: QuotaGauge) -> Bool {
        gauge.state == .active && (gauge.remainingFraction ?? 0) >= lowFraction
    }

    private static func pct(_ gauge: QuotaGauge) -> String { pct(gauge.remainingFraction ?? 0) }
    private static func pct(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}
