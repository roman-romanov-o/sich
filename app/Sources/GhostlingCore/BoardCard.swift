import Foundation

/// The detected lifecycle state a board card is placed by — a faithful port of
/// the Python detector's `SessionState` (`src/mission_control/detector/events.py`),
/// which is the source of truth for the board columns (US-003 AC#1).
///
/// This is distinct from `GhostlingCore.SessionState` (the PTY *process* lifecycle:
/// starting/running/exited/crashed). `CardState` is the *agent-detected* state the
/// board renders — the first six are the US-003 columns; `unknown` is the explicit
/// not-positively-determined indicator (US-004 AC#3), never a guess.
public enum CardState: String, Sendable, Equatable, CaseIterable {
    case idle
    case running
    case waitingForInput = "waiting-for-input"
    case runningTests = "running-tests"
    case blocked
    case done
    case unknown

    /// True for the states that route the operator's attention (US-005):
    /// `waitingForInput` and `blocked`. The single predicate both the attention
    /// derivation and the card view read, so "needs you" is defined once.
    public var needsAttention: Bool {
        self == .waitingForInput || self == .blocked
    }
}

/// Which agentic-coding CLI drives a card's session (cmux metadata, US-003 AC#2).
/// Mirrors the Python `Agent` enum (`src/mission_control/board/card.py`).
public enum CardAgent: String, Sendable, Equatable, CaseIterable {
    case claude
    case codex
    case gemini

    /// The human label rendered on the card face (matches the HELM POC).
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }
}

/// Two-flow tag: `a` autonomous (saha / Agent SDK pool) vs. `b` interactive
/// (human-launched subscription window). Mirrors the Python `Flow` enum.
public enum CardFlow: String, Sendable, Equatable, CaseIterable {
    case a = "A"
    case b = "B"
}

/// One session's board card: identity + cmux metadata + current detected state
/// (US-003 AC#2). A faithful Swift port of the Python `Card` model
/// (`src/mission_control/board/card.py`) — pure data the board renders. Rendering,
/// focus, and timing are the Swift app's job; this model only carries structure.
public struct BoardCard: Identifiable, Sendable, Equatable {
    /// Stable identity, used for selection/drill-in routing.
    public let id: UUID
    public let sessionID: String
    public let projectDir: String
    public let agent: CardAgent
    public let flow: CardFlow
    public let state: CardState

    public init(
        id: UUID = UUID(),
        sessionID: String,
        projectDir: String,
        agent: CardAgent,
        flow: CardFlow,
        state: CardState
    ) {
        self.id = id
        self.sessionID = sessionID
        self.projectDir = projectDir
        self.agent = agent
        self.flow = flow
        self.state = state
    }
}
