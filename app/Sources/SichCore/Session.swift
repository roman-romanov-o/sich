import Foundation

/// Which agentic-coding tool a session runs. The board (Phase 03) and the quota
/// brain (Phase 04) group and bill by this.
public enum AgentType: String, Codable, Sendable, Equatable, CaseIterable {
    case claude
    case codex
    case gemini
    /// A plain interactive shell (no agent), e.g. the default `TerminalSurface`.
    case shell
}

/// Which scheduling flow launched the session — the two-pool distinction the
/// product is built around (see project memory: two-flow thesis).
public enum FlowTag: String, Codable, Sendable, Equatable, CaseIterable {
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
    /// The cwd the running shell has REPORTED via OSC-7 shell-integration (US-004), or
    /// nil until it emits one. This is the "reported, not inferred" signal — distinct
    /// from the launch-time ``projectDir`` — updated live off the PTY stream as the
    /// operator `cd`s inside the session, never derived from a process scan.
    public private(set) var reportedCwd: String?
    /// The Claude conversation id this session was launched to drive (we pin it with
    /// `claude --session-id <uuid>` so we OWN the id up front, never scrape it), or nil
    /// for a bare shell. Persisted per pane so a restart resumes the exact conversation
    /// with `claude --resume <uuid>` — and it survives across restarts unchanged (a
    /// restored session keeps the ORIGINAL id, not its own new ``id``).
    public private(set) var claudeSessionID: UUID?
    /// The remote session this pane is attached to (US-006), or nil for a local one.
    /// Held as the SPEC the argv was built from — never the argv — so a snapshot
    /// persists coordinates a restore feeds back through the shared constructor,
    /// rather than a command a launch could replay.
    public private(set) var remoteSpec: RemoteTmuxSpec?

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

    /// Record a cwd the shell REPORTED semantically (OSC-7 off the live PTY stream).
    /// Public so the app-side output bridge can update it as `cd`s arrive.
    public func reportCwd(_ path: String) {
        reportedCwd = path
    }

    /// Bind the Claude conversation id this session drives, so a later snapshot can
    /// persist it and a restart can `claude --resume` it.
    public func recordClaudeSession(_ id: UUID) {
        claudeSessionID = id
    }

    /// Bind the remote session this pane attached to, so a snapshot can persist the
    /// spec and the next launch can rebuild the same ssh/tmux attach.
    public func recordRemoteSpec(_ spec: RemoteTmuxSpec) {
        remoteSpec = spec
    }
}
