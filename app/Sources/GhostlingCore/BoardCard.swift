import Foundation

/// The detected lifecycle state a board card is placed by — a faithful port of
/// the (now-retired) Python detector's `SessionState`, which was the source of
/// truth for the board columns (US-003 AC#1).
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
/// Mirrors the (now-retired) Python `Agent` enum.
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
/// (US-003 AC#2). A faithful Swift port of the (now-retired) Python `Card` model
/// — pure data the board renders. Rendering, focus, and timing are the Swift app's
/// job; this model only carries structure.
public struct BoardCard: Identifiable, Sendable, Equatable {
    /// Stable identity, used for selection/drill-in routing.
    public let id: UUID
    public let sessionID: String
    /// The human task title the operator gave this card at creation ("Fix login
    /// redirect") — what the work *is*, not the terminal it runs in. `nil` for
    /// hook-observed sessions we never named; the view falls back to the project
    /// dir so an untitled card still reads.
    public let title: String?
    public let projectDir: String
    public let agent: CardAgent
    public let flow: CardFlow
    public let state: CardState
    /// When this card's state was last observed (from the reconciler's
    /// `Entry.updatedAt`). The freshness key the board ranks by when several agent
    /// sessions share one project dir, so a fresh `running` out-ranks a stale
    /// `blocked`/`waiting` from a prior run (US-002 AC#2). Defaults to `.distantPast`
    /// so cards built without an observation time all compare equal and fall back to
    /// the activity-rank tiebreak (preserving the pre-freshness collapse behavior).
    public let updatedAt: Date
    /// For a hook-OBSERVED card only: the owned card's `id` (as a UUID string) this
    /// session was spawned under, carried from the hook line's `ghostling_card_id`.
    /// Lets the merge bind an observed session to its owned card deterministically,
    /// even when several owned cards share one project dir. `nil` for owned cards
    /// and for sessions started outside the app.
    public let boundCardID: String?
    /// Authoritative task artifact folder for saha-flow cards. This is captured at
    /// creation time; it is never recomputed from the project's shared current-task.
    public let taskFolder: String?

    public init(
        id: UUID = UUID(),
        sessionID: String,
        title: String? = nil,
        projectDir: String,
        agent: CardAgent,
        flow: CardFlow,
        state: CardState,
        updatedAt: Date = .distantPast,
        boundCardID: String? = nil,
        taskFolder: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.projectDir = projectDir
        self.agent = agent
        self.flow = flow
        self.state = state
        self.updatedAt = updatedAt
        self.boundCardID = boundCardID
        self.taskFolder = taskFolder.map {
            ($0 as NSString).standardizingPath
        }
    }

    /// The same card in a new lifecycle state — identity, title, dir, agent, and flow
    /// all preserved. Used when only a card's *state* changes (it moves columns): a
    /// manual column drop, or an owned terminal adopting the detected state of the
    /// agent running inside it. Keeps "what the card IS" intact while it moves.
    public func with(state newState: CardState) -> BoardCard {
        BoardCard(
            id: id, sessionID: sessionID, title: title, projectDir: projectDir,
            agent: agent, flow: flow, state: newState, updatedAt: updatedAt,
            boundCardID: boundCardID, taskFolder: taskFolder
        )
    }

    /// The same card renamed — everything else (identity, dir, state, PTY binding
    /// via `id`) preserved, so renaming a live task never disturbs its session.
    /// An empty or whitespace-only name clears the title back to the dir fallback.
    public func with(title newTitle: String?) -> BoardCard {
        let trimmed = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BoardCard(
            id: id, sessionID: sessionID,
            title: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            projectDir: projectDir, agent: agent, flow: flow, state: state,
            updatedAt: updatedAt, boundCardID: boundCardID, taskFolder: taskFolder
        )
    }
}
