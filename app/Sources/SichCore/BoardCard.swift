import Foundation

/// The detected lifecycle state a board card is placed by — a faithful port of
/// the (now-retired) Python detector's `SessionState`, which was the source of
/// truth for the board columns (US-003 AC#1).
///
/// This is distinct from `SichCore.SessionState` (the PTY *process* lifecycle:
/// starting/running/exited/crashed). `CardState` is the *agent-detected* state the
/// board renders — the first six are the US-003 columns; `unknown` is the explicit
/// not-positively-determined indicator (US-004 AC#3), never a guess.
public enum CardState: String, Codable, Sendable, Equatable, CaseIterable {
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

    /// True while the card belongs in the board's WORKING column. Keeping this
    /// grouping next to the state model lets duration tracking follow the exact
    /// same `running` + `runningTests` boundary as board placement.
    public var isWorking: Bool {
        self == .running || self == .runningTests
    }

    /// Where an automatic detector signal may be overridden by prior state.
    /// Terminal completion is sticky: later hook/store observations must not reopen a
    /// done card. Other observations are rendered as observed instead of being guessed
    /// into an attention state.
    public var detectorFallback: CardState? {
        self == .done ? .done : nil
    }

    /// Where an at-rest signal (`idle`/`unknown`) may be overridden by prior state.
    /// Kept as a narrow alias for callers that only reconcile at-rest detector output.
    public var atRestFallback: CardState? {
        detectorFallback
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
    /// When the card most recently entered the WORKING column. It survives the
    /// `running` ↔ `runningTests` sub-state change, and clears as soon as the card
    /// leaves WORKING so a later work interval starts from zero.
    public let workingSince: Date?
    /// Active work completed before the current WORKING interval. This excludes
    /// time spent in Queue / Needs You / Done; while working, ``totalWorkingTime``
    /// adds the live interval without mutating the model every minute.
    public let accumulatedWorkingTime: TimeInterval
    /// When this card's state was last observed (from the reconciler's
    /// `Entry.updatedAt`). The freshness key the board ranks by when several agent
    /// sessions share one project dir, so a fresh `running` out-ranks a stale
    /// `blocked`/`waiting` from a prior run (US-002 AC#2). Defaults to `.distantPast`
    /// so cards built without an observation time all compare equal and fall back to
    /// the activity-rank tiebreak (preserving the pre-freshness collapse behavior).
    public let updatedAt: Date
    /// For a hook-OBSERVED card only: the owned card's `id` (as a UUID string) this
    /// session was spawned under, carried from the hook line's `sich_card_id`.
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
        workingSince: Date? = nil,
        accumulatedWorkingTime: TimeInterval = 0,
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
        self.workingSince = state.isWorking ? workingSince : nil
        self.accumulatedWorkingTime = max(0, accumulatedWorkingTime)
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
    public func with(state newState: CardState, at transitionDate: Date = Date()) -> BoardCard {
        var nextAccumulated = accumulatedWorkingTime
        if state.isWorking, !newState.isWorking, let workingSince {
            nextAccumulated += max(0, transitionDate.timeIntervalSince(workingSince))
        }
        let nextWorkingSince: Date?
        if newState.isWorking {
            nextWorkingSince = state.isWorking ? (workingSince ?? transitionDate) : transitionDate
        } else {
            nextWorkingSince = nil
        }
        return BoardCard(
            id: id, sessionID: sessionID, title: title, projectDir: projectDir,
            agent: agent, flow: flow, state: newState, workingSince: nextWorkingSince,
            accumulatedWorkingTime: nextAccumulated, updatedAt: updatedAt,
            boundCardID: boundCardID, taskFolder: taskFolder
        )
    }

    /// Elapsed time in the current visit to WORKING. Zero in every other column.
    public func currentWorkingTime(at date: Date = Date()) -> TimeInterval {
        guard state.isWorking, let workingSince else { return 0 }
        return max(0, date.timeIntervalSince(workingSince))
    }

    /// Cumulative active work across all completed intervals plus the live one.
    public func totalWorkingTime(at date: Date = Date()) -> TimeInterval {
        accumulatedWorkingTime + currentWorkingTime(at: date)
    }

    /// Overlay a durable total during launch hydration while preserving the
    /// restored card/session identity and current column.
    public func with(accumulatedWorkingTime duration: TimeInterval) -> BoardCard {
        BoardCard(
            id: id, sessionID: sessionID, title: title, projectDir: projectDir,
            agent: agent, flow: flow, state: state, workingSince: workingSince,
            accumulatedWorkingTime: duration, updatedAt: updatedAt,
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
            workingSince: workingSince, accumulatedWorkingTime: accumulatedWorkingTime,
            updatedAt: updatedAt,
            boundCardID: boundCardID, taskFolder: taskFolder
        )
    }
}
