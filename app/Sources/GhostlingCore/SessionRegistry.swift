import Foundation

/// The single source of truth for every managed session — the registry the board
/// (Phase 03) and the state detector (Phase 02) read from.
///
/// Beyond holding sessions, the registry keeps lifecycle state *honest*: a call
/// to ``reconcile()`` polls each running session's process and reflects both a
/// clean exit and an abrupt kill, so a dead session is never left ``running``
/// (TC-E2E-104). It is the registry, not the UI, that owns this invariant.
public final class SessionRegistry {
    private var sessions: [UUID: Session] = [:]

    public init() {}

    /// All sessions, registration order not guaranteed.
    public var all: [Session] { Array(sessions.values) }

    /// Look a session up by id.
    public func session(id: UUID) -> Session? { sessions[id] }

    /// Sessions still believed to be live (`starting` or `running`).
    public var live: [Session] {
        sessions.values.filter {
            switch $0.state {
            case .starting, .running: return true
            case .exited, .crashed: return false
            }
        }
    }

    /// Register a session and mark it `running` (its PTY child is spawned).
    @discardableResult
    public func register(_ session: Session) -> Session {
        sessions[session.id] = session
        session.transition(to: .running)
        return session
    }

    /// Build, register, and start a managed session through the pool firewall.
    /// This is the only place the registry creates PTYs, so the firewall guards
    /// every registry-launched session.
    @discardableResult
    public func launch(
        command argv: [String],
        projectDir: String,
        agentType: AgentType,
        flowTag: FlowTag = .interactive,
        rows: UInt16 = 24,
        cols: UInt16 = 80
    ) throws -> Session {
        let pty = try PTYSession(command: argv, rows: rows, cols: cols)
        try pty.start()
        let session = Session(
            projectDir: projectDir, agentType: agentType, flowTag: flowTag, pty: pty
        )
        return register(session)
    }

    /// Poll every live session's process and reflect any that have died.
    /// Returns the sessions whose state changed this pass.
    @discardableResult
    public func reconcile() -> [Session] {
        live.compactMap { session in
            guard let exit = session.pty.pollExit() else { return nil }
            session.transition(to: exit.isClean ? .exited : .crashed(exit))
            return session
        }
    }

    /// Drop a session from the registry (after it has terminated). Returns the
    /// removed session, if present.
    @discardableResult
    public func remove(id: UUID) -> Session? {
        sessions.removeValue(forKey: id)
    }
}
