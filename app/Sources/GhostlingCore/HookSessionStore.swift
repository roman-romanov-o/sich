import Foundation

/// The detector's per-session state, keyed by Claude `session_id` → `CardState`.
/// The Swift port of `detector/{classifier,reconciler,registry}.py` (the agent-state
/// detector), kept SEPARATE from `SessionRegistry` (which owns our PTY *process*
/// lifecycle, keyed by `UUID`). Conflating the two would mix process exits with
/// agent-detected state; they share nothing but a name.
///
/// `ingest(events:)` folds a (possibly bursty) signal stream into reconciled state
/// using source precedence + sub-second coalescing; `sweepStale(now:)` decays a
/// silent session to `unknown` at the same threshold as the Python `StateReconciler`.
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
    /// NOT "stale" and must not decay to `unknown`. `idle` is a cleared status after
    /// stop; `done`/`blocked` are terminal or action-blocked; `waitingForInput` is an
    /// explicit notification/permission state.
    private static let restingStates: Set<CardState> = [.idle, .done, .blocked, .waitingForInput]

    private let coalesceWindow: TimeInterval
    private let staleThreshold: TimeInterval

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
    ///   - staleThreshold: silence past which a session decays to `unknown`
    ///     (default 30s, matching `DEFAULT_STALE_THRESHOLD`).
    public init(coalesceWindow: TimeInterval = 1, staleThreshold: TimeInterval = 30) {
        self.coalesceWindow = coalesceWindow
        self.staleThreshold = staleThreshold
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

    /// Decay every silent-past-threshold session to `unknown` against the injected
    /// `now` (port of `StateReconciler.tick`, applied to all sessions on the board's
    /// poll cadence — sweep-on-poll, no background timer). A positively terminal
    /// state (`done`/`blocked`) is left untouched.
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
        if now.timeIntervalSince(last) > staleThreshold {
            write(
                sessionID: sessionID, state: Self.settled(prior: entry.state, next: .unknown),
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
        .sessionStart: .running,
        .toolUse: .running,
        .permissionRequest: .waitingForInput,
        .testRunStart: .runningTests,
        .errorExit: .blocked,
        .stop: .idle,
        .sessionEnd: .done,   // the SESSION actually closed — the only real "done"
        .staleTimeout: .unknown,
        .contradictorySignals: .unknown,
        .unknown: .unknown,
    ]

    /// Next state for `prior` given a single signal (port of `classify`). `userInput`
    /// resumes a waiting session to `running`; on any non-waiting prior it leaves the
    /// state untouched rather than guessing.
    private func classify(prior: CardState, event: SignalEvent) -> CardState {
        if event.agent == .codex, event.kind == .sessionStart {
            return .idle
        }
        if event.kind == .userInput {
            // A submitted prompt puts an at-rest session (fresh at its first prompt,
            // or awaiting your reply) to work; other priors are left untouched.
            return prior == .waitingForInput || prior == .idle ? .running : prior
        }
        return Self.settled(prior: prior, next: Self.absolute[event.kind] ?? .unknown)
    }

    /// Preserve sticky terminal state, but do not infer attention from an at-rest
    /// observation. This mirrors cmux's Claude hook integration: `Stop` clears the
    /// running status, while `Notification`/permission hooks are the explicit
    /// "needs input" signal for non-terminal sessions.
    private static func settled(prior: CardState, next: CardState) -> CardState {
        prior.detectorFallback ?? next
    }
}
