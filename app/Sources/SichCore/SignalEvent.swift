import Foundation

/// A normalized lifecycle signal, provider-agnostic — the native port of the
/// (now-retired) Python detector's `SignalKind`.
///
/// `staleTimeout`/`contradictorySignals` are synthesized by the reconciler (not a
/// hook); `unknown` is the catch-all for payloads we can't positively classify
/// (US-003 AC2 — never a false done/waiting claim).
public enum SignalKind: String, Sendable, Equatable {
    case sessionStart = "session-start"
    case toolUse = "tool-use"
    case permissionRequest = "permission-request"
    case userInput = "user-input"
    case subagentStart = "subagent-start"
    case subagentStop = "subagent-stop"
    case testRunStart = "test-run-start"
    case errorExit = "error-exit"
    /// `PreCompact`: the agent is rewriting its own context — WORK, not a wait.
    /// The `SessionStart` re-emitted when compaction completes closes the parenthesis.
    case compaction
    case stop
    /// A clean end-of-session hook (`SessionEnd`): the run closed itself, so it goes
    /// straight to `done` with no 30s stale-decay wait. Distinct from a hard kill,
    /// which POSTs nothing and is reaped by the stale sweep instead.
    case sessionEnd = "session-end"
    case staleTimeout = "stale-timeout"
    case contradictorySignals = "contradictory-signals"
    case unknown
}

/// Where a signal came from — drives reconciliation precedence (hooks > JSONL > PTY).
/// Port of the Python `SignalSource`.
public enum SignalSource: String, Sendable, Equatable {
    case hook
    case jsonl
    case pty
}

/// One normalized signal for a single session — the Swift port of the Python
/// `SignalEvent`. The classifier/reconciler read only `kind`/`source`/`timestamp`;
/// `cwd` is carried through so the board can label a card by its project dir.
public struct SignalEvent: Sendable, Equatable {
    public let kind: SignalKind
    public let source: SignalSource
    public let agent: CardAgent
    public let sessionID: String
    public let timestamp: Date
    /// The project dir a hook carries (`cwd`), if any — used to label the card.
    public let cwd: String?
    /// Identity binding (`sich_card_id`): the board-card UUID string this
    /// session was spawned under, injected into the hook line by the forwarder from
    /// the pty environment. Binds an observed session to its owned card even when
    /// several owned cards share one project dir (the dir join is ambiguous there).
    public let cardID: String?
    /// The machine this signal was observed on (`sich_host`), stamped by the relay
    /// at ingestion — `nil` for a local session. A hook payload carries no hostname
    /// field, so this is the ONLY thing separating two machines that happen to run
    /// the same session id in the same cwd (US-004 AC-3).
    public let host: String?
    /// What the payload's `background_tasks` array reports still running, `nil`
    /// when the payload carries no such array (most hooks, and pre-background-task
    /// Claude versions). A `Stop` that leaves awaited work running is NOT an operator
    /// wait — the turn parked while its work continues (CARD-STATUS.md rule 2.3).
    public let background: BackgroundTasks?

    public init(
        kind: SignalKind,
        source: SignalSource,
        agent: CardAgent = .claude,
        sessionID: String,
        timestamp: Date,
        cwd: String? = nil,
        cardID: String? = nil,
        host: String? = nil,
        background: BackgroundTasks? = nil
    ) {
        self.kind = kind
        self.source = source
        self.agent = agent
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.cwd = cwd
        self.cardID = cardID
        self.host = host
        self.background = background
    }
}

/// The backgrounded work a turn left running (CARD-STATUS.md rule 2.3). The kinds
/// differ in what silence means and in how "awaited" is known: a subagent emits its
/// own hooks, so a silent one is stalled; a monitor is an explicit wait; a shell is
/// awaited unless it turns out to be a long-lived service (a server, an app), which
/// only its live processes can tell — so shells are carried by task id for the
/// store to probe.
public struct BackgroundTasks: Equatable, Sendable {
    /// A backgrounded subagent is still running.
    public var agentRunning: Bool
    /// A monitor (or a task kind this build does not know) is still running.
    public var otherRunning: Bool
    /// Task ids of still-running shells whose command does not already name a
    /// long-lived service.
    public var shellIDs: Set<String>

    public init(agentRunning: Bool = false, otherRunning: Bool = false, shellIDs: Set<String> = []) {
        self.agentRunning = agentRunning
        self.otherRunning = otherRunning
        self.shellIDs = shellIDs
    }
}

/// Shared timestamp parsing for the hook + JSONL normalizers — accepts ISO-8601
/// (with or without fractional seconds) or epoch seconds; a truly absent timestamp
/// stamps `arrival` so staleness measures silence from arrival, not epoch-min
/// (the Python `IngestService` rule both normalizers preserve).
enum SignalTimestamp {
    static func parse(_ raw: Any?, arrival: Date) -> Date {
        if let epoch = raw as? Double {
            return Date(timeIntervalSince1970: epoch)
        }
        if let iso = raw as? String, let date = parseISO(iso) {
            return date
        }
        return arrival
    }

    private static func parseISO(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
