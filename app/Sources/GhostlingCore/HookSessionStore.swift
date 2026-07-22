import Foundation

/// The detector's per-session state, keyed by Claude `session_id` → `CardState`.
/// The Swift port of `detector/{classifier,reconciler,registry}.py` (the agent-state
/// detector), kept SEPARATE from `SessionRegistry` (which owns our PTY *process*
/// lifecycle, keyed by `UUID`). Conflating the two would mix process exits with
/// agent-detected state; they share nothing but a name.
///
/// `ingest(events:)` folds a (possibly bursty) signal stream into reconciled state
/// using source precedence + sub-second coalescing; `sweepStale(now:)` is the
/// CARD-STATUS.md rule-2.1 stall guard: a WORKING session silent past the stall
/// threshold moves to `waitingForInput` (NEEDS YOU) — a genuinely progressing agent
/// emits *something*, so long silence means hung, stuck on a hidden prompt, or dead.
/// The clock is always injected (`now:` / event timestamps) — the store never reads
/// the wall clock, mirroring the Python `now=`/`clock=` seam (deterministic tests).
public final class HookSessionStore {

    /// One session's detected state + the project dir to label it by.
    public struct Entry: Sendable, Equatable {
        public let sessionID: String
        public let agent: CardAgent
        public let state: CardState
        public let updatedAt: Date
        public let projectDir: String?
        /// Identity binding carried from the hook line (`ghostling_card_id`), if the
        /// session was spawned inside one of our own cards' ptys.
        public let cardID: String?

        public init(
            sessionID: String, agent: CardAgent = .claude, state: CardState, updatedAt: Date,
            projectDir: String?, cardID: String? = nil
        ) {
            self.sessionID = sessionID
            self.agent = agent
            self.state = state
            self.updatedAt = updatedAt
            self.projectDir = projectDir
            self.cardID = cardID
        }
    }

    /// Source precedence (port of `_SOURCE_RANK`): hooks > JSONL > PTY.
    private static let sourceRank: [SignalSource: Int] = [.hook: 3, .jsonl: 2, .pty: 1]

    /// Resting states — the session is deliberately quiet, so silence after them is
    /// NOT a stall and must not trip the guard. `idle`/`unknown` are at-rest (QUEUE);
    /// `done`/`blocked` are terminal or action-blocked; `waitingForInput` already IS
    /// the attention state the guard would move to.
    private static let restingStates: Set<CardState> =
        [.idle, .unknown, .done, .blocked, .waitingForInput]

    private let coalesceWindow: TimeInterval
    private let stallThreshold: TimeInterval

    private var bySession: [String: Entry] = [:]
    private var projectDir: [String: String] = [:]
    private var agentBySession: [String: CardAgent] = [:]
    // Carry-forward like projectDir: a later card-id-less signal (e.g. stale sweep)
    // must not erase an identity binding an earlier hook established.
    private var cardID: [String: String] = [:]
    private var lastEventAt: [String: Date] = [:]
    // Emitted state path per session (a transition is recorded only on a real state
    // change), mirroring the Python `StateReconciler.transitions_for` — the parity
    // diff (TC-INT-324) asserts on this, not just the final state.
    private var transitionsBySession: [String: [CardState]] = [:]

    /// - Parameters:
    ///   - coalesceWindow: sub-second burst window (default 1s, matching
    ///     `DEFAULT_COALESCE_WINDOW`).
    ///   - stallThreshold: WORKING silence past which the session is declared stalled
    ///     and moves to `waitingForInput` (CARD-STATUS.md rule 2.1; default 10 min).
    ///     A quiet subagent wait gets the same budget: subagent tool calls still fire
    ///     hooks, so a genuinely progressing child resets the timer anyway.
    public init(coalesceWindow: TimeInterval = 1, stallThreshold: TimeInterval = 600) {
        self.coalesceWindow = coalesceWindow
        self.stallThreshold = stallThreshold
    }

    /// Every tracked session's current entry.
    public var entries: [Entry] { Array(bySession.values) }

    /// One session's current entry, or `nil` if untracked.
    public func entry(for sessionID: String) -> Entry? { bySession[sessionID] }

    /// The emitted state path for a session, in order (one entry per real change) —
    /// the parity surface equivalent to `StateReconciler.transitions_for`.
    public func transitions(for sessionID: String) -> [CardState] {
        transitionsBySession[sessionID] ?? []
    }

    /// Fold a batch of normalized events into reconciled per-session state. Events
    /// are grouped by session, then each session's stream is coalesced + applied —
    /// matching the Python `StateReconciler.ingest` per-session contract.
    public func ingest(_ events: [SignalEvent]) {
        for (sessionID, stream) in Dictionary(grouping: events, by: \.sessionID) {
            for burst in coalesce(stream) {
                applyBurst(sessionID: sessionID, burst: burst)
            }
        }
    }

    /// The stall guard (CARD-STATUS.md rule 2.1), applied to all sessions on the
    /// board's poll cadence — sweep-on-poll, no background timer. A WORKING session
    /// silent past `stallThreshold` moves to `waitingForInput` (NEEDS YOU): the
    /// operator should look at a hung/stuck/dead loop. At-rest and terminal states
    /// are left untouched, and any new observed event puts the session back to
    /// WORKING through the normal classifier (which also resets the timer).
    public func sweepStale(now: Date) {
        for sessionID in bySession.keys {
            tick(sessionID: sessionID, now: now)
        }
    }

    // MARK: - Reconciliation (port of reconciler.py)

    /// Group consecutive events into sub-`coalesceWindow` bursts, ordered by time
    /// (port of `_coalesce`).
    private func coalesce(_ events: [SignalEvent]) -> [[SignalEvent]] {
        let ordered = events.sorted { $0.timestamp < $1.timestamp }
        var groups: [[SignalEvent]] = []
        for event in ordered {
            if let last = groups.last?.first,
               event.timestamp.timeIntervalSince(last.timestamp) <= coalesceWindow {
                groups[groups.count - 1].append(event)
            } else {
                groups.append([event])
            }
        }
        return groups
    }

    /// The burst's deciding event: highest precedence, then latest (port of `_dominant`).
    private func dominant(_ burst: [SignalEvent]) -> SignalEvent {
        burst.max { lhs, rhs in
            let lr = Self.sourceRank[lhs.source] ?? 0
            let rr = Self.sourceRank[rhs.source] ?? 0
            return lr != rr ? lr < rr : lhs.timestamp < rhs.timestamp
        }!
    }

    /// Classify a coalesced burst by its dominant event and write once (port of
    /// `_apply_burst`).
    private func applyBurst(sessionID: String, burst: [SignalEvent]) {
        let decisive = dominant(burst)
        lastEventAt[sessionID] = burst.map(\.timestamp).max()!
        let next = classify(prior: currentState(sessionID), event: decisive)
        write(
            sessionID: sessionID, state: next, at: decisive.timestamp,
            projectDir: decisive.cwd, cardID: decisive.cardID, agent: decisive.agent
        )
    }

    private func tick(sessionID: String, now: Date) {
        guard let entry = bySession[sessionID], let last = lastEventAt[sessionID],
              !Self.restingStates.contains(entry.state) else { return }
        if now.timeIntervalSince(last) > stallThreshold {
            write(
                sessionID: sessionID,
                state: Self.settled(prior: entry.state, next: .waitingForInput),
                at: now, projectDir: nil, cardID: nil, agent: nil
            )
        }
    }

    private func currentState(_ sessionID: String) -> CardState {
        bySession[sessionID]?.state ?? .idle
    }

    /// Record `state` as the session's current state; a later state-only signal must
    /// not erase a project dir an earlier hook established (port of the registry's
    /// `_project_dir` carry-forward). A transition is logged only when the state
    /// actually changes (port of `_emit`'s no-flicker rule).
    private func write(
        sessionID: String, state: CardState, at: Date, projectDir dir: String?,
        cardID id: String?, agent: CardAgent?
    ) {
        if let dir, !dir.isEmpty { projectDir[sessionID] = dir }
        if let id, !id.isEmpty { cardID[sessionID] = id }
        if let agent { agentBySession[sessionID] = agent }
        let changed = state != currentState(sessionID)
        bySession[sessionID] = Entry(
            sessionID: sessionID, agent: agentBySession[sessionID] ?? .claude,
            state: state, updatedAt: at,
            projectDir: projectDir[sessionID], cardID: cardID[sessionID]
        )
        if changed { transitionsBySession[sessionID, default: []].append(state) }
    }

    // MARK: - Classification (port of classifier.py)

    /// Signals whose target state never depends on the prior state (port of `_ABSOLUTE`).
    private static let absolute: [SignalKind: CardState] = [
        .toolUse: .running,
        .subagentStart: .running,
        .permissionRequest: .waitingForInput,
        .testRunStart: .runningTests,
        .errorExit: .blocked,
        // Stop is the root turn boundary (CARD-STATUS.md rule 3): the agent finished
        // its turn and is idle until the operator types — the attention signal the
        // board exists for. Queue is reserved for work that has not started.
        .stop: .waitingForInput,
        .staleTimeout: .unknown,
        .contradictorySignals: .unknown,
        .unknown: .unknown,
    ]

    /// Next state for `prior` given a single signal (port of `classify`). `userInput`
    /// resumes a waiting session to `running`; on any non-waiting prior it leaves the
    /// state untouched rather than guessing.
    private func classify(prior: CardState, event: SignalEvent) -> CardState {
        switch event.kind {
        case .sessionStart:
            // NEUTRAL: launching an agent is not starting work (CARD-STATUS.md
            // rule 1 — a created card auto-launches claude, and it must stay QUEUE
            // until the first prompt). Claude also re-emits SessionStart mid-session
            // on `--resume`, `/clear`, and compaction, so the prior must survive.
            // A fresh session gets `currentState`'s at-rest default and still lands
            // an entry (the write carries cwd + card binding).
            return prior
        case .subagentStop:
            // NEUTRAL: a child finishing says nothing about the root turn — mid-run
            // it is still running, and a straggler SubagentStop landing after the
            // root Stop must not revive a waiting session to WORKING.
            return prior
        case .sessionEnd:
            // The process exited — a RESUMABLE rest, not task-done. DONE is manual
            // and board-owned only (CARD-STATUS.md rule 4): app restarts fire
            // SessionEnd and then `claude --resume` the SAME session id, so a
            // sticky store-level done would swallow every post-restart hook.
            return Self.settled(prior: prior, next: .idle)
        case .userInput:
            // A submitted prompt puts an at-rest session (fresh at its first prompt,
            // or awaiting your reply) to work; other priors are left untouched.
            return prior == .waitingForInput || prior == .idle ? .running : prior
        default:
            return Self.settled(prior: prior, next: Self.absolute[event.kind] ?? .unknown)
        }
    }

    /// Preserve sticky terminal state (`done` is manual-and-sticky per CARD-STATUS.md
    /// rule 4): a detector signal never overrides it; everything else takes the
    /// classified `next`.
    private static func settled(prior: CardState, next: CardState) -> CardState {
        prior.detectorFallback ?? next
    }
}
