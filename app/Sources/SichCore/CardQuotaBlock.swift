import Foundation

/// Per-card quota capacity — derived from the card's harness + account and the
/// matching pool gauge. Distinct from ``CardState/blocked`` (agent error).
public enum CardQuotaBlock: Sendable, Equatable {
    case none
    case low(remainingPercent: Int, reset: Date?)
    case exhausted(reset: Date?)

    public var isBlocked: Bool {
        switch self {
        case .none: return false
        case .low, .exhausted: return true
        }
    }

    /// Short label for the card chip.
    public var chipText: String {
        switch self {
        case .none: return ""
        case .low: return "pool low"
        case .exhausted: return "quota spent"
        }
    }

    /// Tooltip with countdown when a reset time is known.
    public func toolTip(now: Date = Date()) -> String {
        switch self {
        case .none: return ""
        case .low(let pct, let reset):
            var tip = "Interactive pool low (\(pct)% left)"
            if let reset, reset > now {
                tip += " — back in \(Self.relative(until: reset, from: now))"
            }
            return tip
        case .exhausted(let reset):
            var tip = "This harness/account's quota is spent"
            if let reset, reset > now {
                tip += " — back in \(Self.relative(until: reset, from: now))"
            }
            return tip
        }
    }

    private static func relative(until reset: Date, from now: Date) -> String {
        let minutes = max(1, Int((reset.timeIntervalSince(now) / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

/// Maps a board card to its primary quota pool and reads exhaustion from live gauges.
public enum CardQuotaAdvisor {
    /// Below a quarter of a pool left, cards on it read as low.
    public static let lowFraction = 0.25

    public static func block(
        for card: BoardCard,
        profileID: UUID?,
        claudeProfiles: [ClaudeProfile],
        gauges: [QuotaGauge]
    ) -> CardQuotaBlock {
        let provider = provider(for: card.agent)
        let pool = primaryPool(for: card, profileID: profileID, claudeProfiles: claudeProfiles)
        guard let gauge = gauge(provider: provider, pool: pool, in: gauges) else { return .none }
        switch gauge.state {
        case .unknown: return .none
        case .exhausted: return .exhausted(reset: gauge.reset)
        case .active:
            if let fraction = gauge.remainingFraction, fraction < lowFraction {
                return .low(
                    remainingPercent: Int((fraction * 100).rounded()),
                    reset: gauge.reset)
            }
            return .none
        }
    }

    private static func provider(for agent: CardAgent) -> String {
        switch agent {
        case .claude: return "anthropic"
        case .codex: return "codex"
        case .cursor: return "cursor"
        case .antigravity: return "antigravity"
        case .gemini: return "gemini"
        }
    }

    private static func primaryPool(
        for card: BoardCard,
        profileID: UUID?,
        claudeProfiles: [ClaudeProfile]
    ) -> String {
        switch card.agent {
        case .claude:
            let pid = profileID ?? ClaudeProfile.defaultID
            let profile = claudeProfiles.first { $0.id == pid } ?? .defaultProfile
            return profile.poolPrefix
        case .codex: return "codex"
        case .cursor: return "cursor"
        case .antigravity: return "antigravity"
        case .gemini: return "gemini"
        }
    }

    private static func gauge(provider: String, pool: String, in gauges: [QuotaGauge]) -> QuotaGauge? {
        let normPool = normalized(pool)
        return gauges.first {
            $0.provider.lowercased() == provider.lowercased()
                && normalized($0.pool) == normPool
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: "_")
    }
}
