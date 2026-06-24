import Foundation

/// Which agentic-coding tool a session runs. The board (Phase 03) and the quota
/// brain (Phase 04) group and bill by this.
public enum AgentType: String, Sendable, Equatable, CaseIterable {
    case claude
    case codex
    case gemini
    /// A plain interactive shell (no agent), e.g. the default `TerminalSurface`.
    case shell
}

/// Which scheduling flow launched the session — the two-pool distinction the
/// product is built around (see project memory: two-flow thesis).
public enum FlowTag: String, Sendable, Equatable, CaseIterable {
    case interactive
    case backlog
}

/// The lifecycle state of a managed session. `SessionRegistry` is the single
/// source of truth Phase 02/03 read from; a session must never be left
/// ``running`` after its process has died (TC-E2E-104).
public enum SessionState: Sendable, Equatable {
    case starting
    case running
    /// Process exited cleanly (code 0).
    case exited
    /// Process ended with a non-zero exit code or a terminating signal.
    case crashed(ProcessExit)
}

/// Metadata for one managed session plus the PTY it runs in.
///
/// The PTY handle is the keystone read/write path (``PTYSession``); the rest is
/// the typed metadata the board and detector consume. Reference type because a
/// session's state mutates in place as its process advances.
public final class Session: Identifiable {
    public let id: UUID
    public let projectDir: String
    public let agentType: AgentType
    public let flowTag: FlowTag
    public let pty: PTYSession
    public private(set) var state: SessionState

    public init(
        id: UUID = UUID(),
        projectDir: String,
        agentType: AgentType,
        flowTag: FlowTag,
        pty: PTYSession,
        state: SessionState = .starting
    ) {
        self.id = id
        self.projectDir = projectDir
        self.agentType = agentType
        self.flowTag = flowTag
        self.pty = pty
        self.state = state
    }

    /// Transition into the given state. Used by ``SessionRegistry``.
    func transition(to newState: SessionState) {
        state = newState
    }
}
