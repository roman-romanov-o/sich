import Foundation

/// The board's state columns — a faithful port of the (now-retired) Python `Column`
/// enum: the six US-003 state-columns plus an explicit `unknown` for the
/// not-positively-determined case (US-004 AC#3).
///
/// `allCases` is the canonical left-to-right ordering the renderer draws. The
/// HELM POC merges `waitingForInput`+`blocked` into one visual `⚠ attention`
/// group; that is a *rendering* concern (`BoardColumn.attentionGroup`) — the
/// underlying state column stays distinct here.
public enum BoardColumn: String, Sendable, Equatable, CaseIterable {
    case idle
    case running
    case waitingForInput = "waiting-for-input"
    case runningTests = "running-tests"
    case blocked
    case done
    case unknown

    /// The state→column mapping, mirroring Python `_STATE_COLUMN`.
    /// `unknown`/stale → `unknown`, never silently `running` or guessed `done`.
    public init(state: CardState) {
        switch state {
        case .idle: self = .idle
        case .running: self = .running
        case .waitingForInput: self = .waitingForInput
        case .runningTests: self = .runningTests
        case .blocked: self = .blocked
        case .done: self = .done
        case .unknown: self = .unknown
        }
    }

    /// True for the two columns the HELM POC renders together under one
    /// `⚠ waiting · blocked` header (US-005 made structural).
    public var isAttention: Bool {
        self == .waitingForInput || self == .blocked
    }

    /// The state a manual drop into this column sets — the inverse of
    /// `init(state:)`. The rawValues are shared 1:1, so this is total and exact.
    public var state: CardState {
        CardState(rawValue: rawValue) ?? .unknown
    }
}

/// Group cards into their state columns — one card per session, stable input
/// ordering. A faithful port of Python `place()`.
///
/// Every column key is present (empty array when nothing lands there) so a
/// renderer can draw all columns without re-deriving the set.
public func placeCards(_ cards: [BoardCard]) -> [BoardColumn: [BoardCard]] {
    var placed: [BoardColumn: [BoardCard]] = [:]
    for column in BoardColumn.allCases { placed[column] = [] }
    for card in cards {
        placed[BoardColumn(state: card.state), default: []].append(card)
    }
    return placed
}
