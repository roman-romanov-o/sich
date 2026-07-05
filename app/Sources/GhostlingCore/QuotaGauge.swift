import Foundation

/// Whether a remaining value is observed or derived (interactive window math).
/// A faithful Swift port of the Python `Confidence` enum (`quota/models.py`):
/// inferred readings are `.estimated`, measured ones are `.measured`. AC#3
/// requires the estimated case be shown, never as false precision.
public enum QuotaConfidence: String, Sendable, Equatable {
    case measured
    case estimated
}

/// Coarse availability of a pool — port of the Python `PoolState`. `.unknown` is
/// the explicit "no usable signal" state: it is NOT 0 and NOT 100% (TC-INT-103 /
/// US-006 edge case #2), so the UI must read it as "not tracked", never free.
public enum QuotaPoolState: String, Sendable, Equatable {
    case active
    case exhausted
    case unknown
}

/// How a pool replenishes — port of the Python `RefillKind`. The asymmetry is
/// load-bearing (TC-INT-104 / TC-E2E-204): the Agent SDK credit is a monthly
/// hard-stop with no interactive fallback; the interactive pool refills as usage
/// ages out of the rolling window and on the weekly reset.
public enum QuotaRefillKind: String, Sendable, Equatable {
    case monthlyHardStop = "monthly_hard_stop"
    case rollingWindow = "rolling_window"
    case weekly
    case unknown
}

/// What a pool falls back to once exhausted — port of the Python `Fallback`
/// literal. `.none` = hard-stop (Agent SDK credit); the window/weekly resets are
/// the interactive pool's recovery path. This is the asymmetry AC#1/edge case #1
/// require the panel to surface.
public enum QuotaFallback: String, Sendable, Equatable {
    case none
    case windowReset = "window_reset"
    case weeklyReset = "weekly_reset"
    case unknown
}

/// The typed value a quota source adapter returns — port of the Python
/// `SourceReading` (`quota/models.py`). Carries `available` + `inferred` so the
/// projection can map them to state and confidence without re-deciding policy.
public struct QuotaSourceReading: Sendable, Equatable {
    public let available: Bool
    public let inferred: Bool
    public let remainingFraction: Double?
    public let remainingAmount: Double?
    public let unit: String?
    public let reset: Date?
    public let refillKind: QuotaRefillKind
    public let state: QuotaPoolState

    public init(
        available: Bool = true,
        inferred: Bool = false,
        remainingFraction: Double? = nil,
        remainingAmount: Double? = nil,
        unit: String? = nil,
        reset: Date? = nil,
        refillKind: QuotaRefillKind = .unknown,
        state: QuotaPoolState = .active
    ) {
        self.available = available
        self.inferred = inferred
        self.remainingFraction = remainingFraction
        self.remainingAmount = remainingAmount
        self.unit = unit
        self.reset = reset
        self.refillKind = refillKind
        self.state = state
    }
}

/// An independent, renderable gauge for a single quota pool — a faithful Swift
/// port of the Python `PoolGauge` (`quota/models.py`). Never combined with another
/// pool: the two Anthropic pools do not fungibly trade (`research/10`), so no
/// arithmetic nets one against another. This is the value type `QuotaPanel`
/// renders, kept pure so the projection is unit-testable in isolation.
public struct QuotaGauge: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let provider: String
    public let pool: String
    public let state: QuotaPoolState
    public let confidence: QuotaConfidence
    public let refillKind: QuotaRefillKind
    public let fallback: QuotaFallback
    public let remainingFraction: Double?
    public let remainingAmount: Double?
    public let unit: String?
    public let reset: Date?

    public init(
        id: UUID = UUID(),
        provider: String,
        pool: String,
        state: QuotaPoolState,
        confidence: QuotaConfidence,
        refillKind: QuotaRefillKind = .unknown,
        fallback: QuotaFallback = .unknown,
        remainingFraction: Double? = nil,
        remainingAmount: Double? = nil,
        unit: String? = nil,
        reset: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.pool = pool
        self.state = state
        self.confidence = confidence
        self.refillKind = refillKind
        self.fallback = fallback
        self.remainingFraction = remainingFraction
        self.remainingAmount = remainingAmount
        self.unit = unit
        self.reset = reset
    }
}

/// A labelled quota source: identity (`provider`/`pool`) plus its current reading.
/// Mirrors the Python `QuotaSource` Protocol carrying its own labels so the
/// projection can place each reading on its own independent gauge. The reading is
/// injected (not read live) — the rendering harness and tests stub it, never
/// hitting a provider endpoint (the watcher constraint applied to the panel).
public struct QuotaSourceInput: Sendable, Equatable {
    public let provider: String
    public let pool: String
    public let reading: QuotaSourceReading

    public init(provider: String, pool: String, reading: QuotaSourceReading) {
        self.provider = provider
        self.pool = pool
        self.reading = reading
    }
}

/// Projects injected source readings onto independent pool gauges — a faithful
/// Swift port of `quota/aggregator.py`. The rules mirror the Python EXACTLY:
///
/// - one gauge per source, in source order — pools are NEVER netted against each
///   other (the two Anthropic pools do not fungibly trade, `research/10`);
/// - an unavailable source becomes `.unknown` with NO remaining value (not 0, not
///   100% — TC-INT-103 / US-006 edge case #2);
/// - an inferred reading is `.estimated`; a measured one is `.measured` (AC#3);
/// - the fallback is derived from the refill kind so hard-stop vs. window/weekly
///   recovery is explicit (TC-INT-104 / TC-E2E-204).
public enum QuotaProjection {
    private static let fallbackByRefill: [QuotaRefillKind: QuotaFallback] = [
        .monthlyHardStop: .none,
        .rollingWindow: .windowReset,
        .weekly: .weeklyReset,
        .unknown: .unknown,
    ]

    /// Inferred readings are estimated; measured ones are measured (AC#3).
    private static func confidence(_ reading: QuotaSourceReading) -> QuotaConfidence {
        reading.inferred ? .estimated : .measured
    }

    /// An unavailable source is `.unknown`; otherwise trust the source's state.
    private static func state(_ reading: QuotaSourceReading) -> QuotaPoolState {
        reading.available ? reading.state : .unknown
    }

    /// Project one source's reading onto its own independent gauge. An absent
    /// source yields `.unknown` with no remaining value — not 0, not 100%.
    public static func gauge(for source: QuotaSourceInput) -> QuotaGauge {
        let reading = source.reading
        let resolved = state(reading)
        if resolved == .unknown {
            // An unavailable source has NO value to infer, so it cannot be
            // "estimated" — "unknown / not tracked" already fully describes its
            // confidence. Carrying `.estimated` here renders a contradictory
            // badge (estimated AND unknown on the same row). The `.estimated`
            // rule applies only to readings that actually carry a value.
            return QuotaGauge(
                provider: source.provider,
                pool: source.pool,
                state: .unknown,
                confidence: .measured
            )
        }
        return QuotaGauge(
            provider: source.provider,
            pool: source.pool,
            state: resolved,
            confidence: confidence(reading),
            refillKind: reading.refillKind,
            fallback: fallbackByRefill[reading.refillKind] ?? .unknown,
            remainingFraction: reading.remainingFraction,
            remainingAmount: reading.remainingAmount,
            unit: reading.unit,
            reset: reading.reset
        )
    }

    /// One gauge per source, in source order. No cross-pool arithmetic — the
    /// invariant that makes the two-pool split honest (`research/10`).
    public static func gauges(from sources: [QuotaSourceInput]) -> [QuotaGauge] {
        sources.map(gauge(for:))
    }
}
