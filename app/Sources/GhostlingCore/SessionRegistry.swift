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

    /// The registry's sessions as a restore snapshot's windows (US-003 save side).
    /// Core has no window layout of its own, so this yields a single window; the app
    /// layer may regroup into several windows before persisting. A pane records the
    /// session's cwd + identity and its live child PID (used only for reopen-vs-dead
    /// on restore) — never the agent command.
    public func snapshotWindows() -> [WindowSnapshot] {
        let panes = all.map { session in
            PaneSnapshot(
                sessionID: session.id,
                cwd: session.projectDir,
                agentType: session.agentType,
                flowTag: session.flowTag,
                childPID: session.pty.childPID > 0 ? session.pty.childPID : nil
            )
        }
        return panes.isEmpty ? [] : [WindowSnapshot(panes: panes)]
    }
}

/// Persists the session-tree snapshot on quit and reloads it on launch (US-003).
///
/// Writes a `current` file; on a *successful* load it rotates that snapshot to a
/// `-previous` last-known-good, so a corrupt/partial/version-mismatched `current`
/// falls back to `-previous` rather than starting blank or crashing. The snapshot
/// directory is injectable so tests never touch the real Application Support; the
/// clock is injectable so `createdAt` is deterministic (no wall-clock assertions).
public final class SessionSnapshotStore {
    private let directory: URL
    private let clock: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.clock = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// The store rooted under `Application Support/Ghostling` (resolved once). Falls
    /// back to the temp dir only if Application Support is somehow unavailable.
    public static func applicationSupport(now: @escaping () -> Date = Date.init) -> SessionSnapshotStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return SessionSnapshotStore(
            directory: base.appendingPathComponent("Ghostling", isDirectory: true), now: now
        )
    }

    public var currentURL: URL { directory.appendingPathComponent("sessions-current.json") }
    public var previousURL: URL { directory.appendingPathComponent("sessions-previous.json") }

    /// Persist `windows` as a fresh, current-versioned snapshot stamped with the
    /// injected clock (the quit path).
    @discardableResult
    public func save(windows: [WindowSnapshot]) throws -> SessionSnapshot {
        let snapshot = SessionSnapshot(createdAt: clock(), windows: windows)
        try save(snapshot)
        return snapshot
    }

    /// Persist an explicit snapshot to `current` (atomic write).
    public func save(_ snapshot: SessionSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: currentURL, options: .atomic)
    }

    /// The newest usable snapshot: prefer `current`, rotating it to `-previous` on a
    /// successful decode; otherwise fall back to `-previous`. `nil` means start clean
    /// — never a blank crash on a corrupt/partial/version-mismatched file.
    public func load() -> SessionSnapshot? {
        if let snapshot = decodeUsable(at: currentURL) {
            rotateCurrentToPrevious()
            return snapshot
        }
        return decodeUsable(at: previousURL)
    }

    /// Decode a snapshot only if it parses AND matches the current schema version;
    /// a version mismatch (edge case 1) or corruption (AC-3) yields `nil`, never a throw.
    private func decodeUsable(at url: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(SessionSnapshot.self, from: data),
              snapshot.version == SessionSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    /// Promote the just-loaded `current` to the `-previous` last-known-good.
    private func rotateCurrentToPrevious() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: currentURL.path) else { return }
        try? fm.removeItem(at: previousURL)
        try? fm.copyItem(at: currentURL, to: previousURL)
    }
}

/// Rebuilds panes from a loaded ``SessionSnapshot`` **without ever resurrecting an
/// agent** (US-003 / DD-001 watcher posture).
///
/// For each pane it resolves the cwd (falling back to home when the original
/// directory is gone) and decides reopen-vs-dead from process liveness. A reopened
/// pane is handed a **plain interactive shell** command — the agent command was
/// never stored, and the command is routed through ``PoolFirewall`` — so restore
/// can never spawn a print-mode headless agent or any other process. The liveness check, cwd
/// check, home dir, and reopen action are all injectable, so tests assert via a
/// spawn spy and injected state (no wall-clock, no real process).
public final class SessionRestorer {
    public typealias LivenessCheck = (Int32) -> Bool
    public typealias Reopen = (RestoredPane, [String]) -> Void

    private let isAlive: LivenessCheck
    private let directoryExists: (String) -> Bool
    private let homeDirectory: String
    private let shellPath: String
    private let reopen: Reopen

    public init(
        isAlive: @escaping LivenessCheck = PTYSession.isProcessAlive,
        directoryExists: @escaping (String) -> Bool = SessionRestorer.pathIsDirectory,
        homeDirectory: String = NSHomeDirectory(),
        shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        reopen: @escaping Reopen
    ) {
        self.isAlive = isAlive
        self.directoryExists = directoryExists
        self.homeDirectory = homeDirectory
        self.shellPath = shellPath
        self.reopen = reopen
    }

    /// Restore every pane, preserving window/pane order (the pre-quit layout).
    public func restore(_ snapshot: SessionSnapshot) -> [RestoredPane] {
        snapshot.windows.flatMap { window in
            window.panes.map { self.restore(pane: $0) }
        }
    }

    private func restore(pane: PaneSnapshot) -> RestoredPane {
        let (cwd, fellBack) = resolveCwd(pane.cwd)
        let alive = pane.childPID.map(isAlive) ?? true
        let restored = RestoredPane(
            snapshot: pane, cwd: cwd, cwdFellBackToHome: fellBack,
            liveness: alive ? .reopened : .dead
        )
        if restored.liveness == .reopened { reopenShell(for: restored) }
        return restored
    }

    /// Re-open a plain interactive shell at the pane's cwd. The agent command is
    /// intentionally absent and the shell command is routed through the pool
    /// firewall, so restore can never resurrect a headless agent.
    private func reopenShell(for pane: RestoredPane) {
        let command = [shellPath, "-il"]
        guard (try? PoolFirewall.classify(command)) != nil else { return }
        reopen(pane, command)
    }

    private func resolveCwd(_ cwd: String) -> (path: String, fellBack: Bool) {
        directoryExists(cwd) ? (cwd, false) : (homeDirectory, true)
    }

    /// Default cwd-existence probe: the path is a real, existing directory.
    public static func pathIsDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
