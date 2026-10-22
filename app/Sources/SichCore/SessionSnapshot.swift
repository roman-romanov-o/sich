import Foundation

/// A versioned, `Codable` snapshot of the open window/pane tree, persisted on quit
/// and restored on launch (US-003). Shape is `{createdAt, version, windows}`.
///
/// A pane records **cwd + session identity** only — never the agent command — so a
/// restore can re-open a shell but can't resurrect a headless agent (the
/// watcher-not-spawner invariant lives in the *shape* of what we persist, not just
/// the restore code).
public struct SessionSnapshot: Codable, Equatable, Sendable {
    /// Bump when the on-disk shape changes. A snapshot whose `version` differs is
    /// ignored (start clean) rather than crashed on — US-003 edge case 1.
    public static let currentVersion = 1

    public let createdAt: Date
    public let version: Int
    public let windows: [WindowSnapshot]

    public init(
        createdAt: Date,
        version: Int = SessionSnapshot.currentVersion,
        windows: [WindowSnapshot]
    ) {
        self.createdAt = createdAt
        self.version = version
        self.windows = windows
    }
}

/// One window in the persisted tree: an ordered list of panes. Core has no window
/// layout model of its own, so a single window is the natural default; the app
/// layer may group panes into several windows before persisting.
public struct WindowSnapshot: Codable, Equatable, Sendable {
    public let panes: [PaneSnapshot]
    public init(panes: [PaneSnapshot]) { self.panes = panes }
}

/// Where a pane's REMOTE session lives, in the only form we persist: the
/// constructor's **input**, never its output.
///
/// This is the whole watcher argument in one shape. An argv on disk would be a
/// command a launch replays with no human present; a spec is a set of constrained
/// coordinates (host, login, session name, port, key, dir) that only
/// ``RemoteTmuxCommand/argv(for:cardID:)`` can turn into a command — so the
/// destination grammar, the pool firewall and the tmux shape are re-applied on
/// every restore instead of being frozen into the file. Nothing here can name a
/// command, which is why widening it is a decision, not a detail.
public struct RemoteSpecSnapshot: Codable, Equatable, Sendable {
    public let host: String
    public let user: String?
    public let sessionName: String
    public let port: Int?
    public let identityFile: String?
    public let remoteDir: String?
    /// Optional so a pre-windows snapshot decodes (nil → `.posix`, no version bump);
    /// always written going forward — a psmux card must restore as a psmux card.
    public let hostKind: RemoteHostKind?

    public init(spec: RemoteTmuxSpec) {
        host = spec.host
        user = spec.user
        sessionName = spec.sessionName
        port = spec.port
        identityFile = spec.identityFile
        remoteDir = spec.remoteDir
        hostKind = spec.hostKind
    }

    /// The spec this snapshot was made of — the input a rebuild feeds back into the
    /// shared argv constructor.
    public var spec: RemoteTmuxSpec {
        RemoteTmuxSpec(
            host: host, user: user, sessionName: sessionName,
            port: port, identityFile: identityFile, remoteDir: remoteDir,
            hostKind: hostKind ?? .posix)
    }
}

/// One pane's restorable identity: **cwd + session identity** plus the child PID
/// captured at snapshot time. The PID is used only to decide reopen-vs-closed on
/// restore — never to re-attach — and the agent command is deliberately not stored.
public struct PaneSnapshot: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let cwd: String
    public let agentType: AgentType
    public let flowTag: FlowTag
    public let childPID: Int32?
    /// The Claude conversation id the pane was driving, if any — the resume token a
    /// restart replays with `claude --resume <uuid>`. Optional (decodes to nil from a
    /// pre-resume v1 snapshot, so no version bump is needed) and nil for a bare shell:
    /// this is the ONE thing beyond cwd we persist so a restore can pick a conversation
    /// back up. It is still not the agent *command* — the watcher invariant holds; we
    /// only re-attach an interactive conversation the operator already started.
    public let claudeSessionID: UUID?
    /// The human task title the operator gave this pane's card ("Fix login redirect").
    /// Persisted so a restart brings the *task* back by name, not an unnamed shell at
    /// the same cwd. Optional (decodes nil from a pre-title snapshot → no version bump,
    /// same precedent as `claudeSessionID`) and nil for a card that was never named.
    public let title: String?
    /// The saha task-artifact folder this card was bound to at creation, if any —
    /// captured so a restored saha-flow card still points at its own task, not the
    /// project's shifting current-task. Optional for the same back-compat reason.
    public let taskFolder: String?
    /// The board card's stable `id` this pane belongs to. Persisted so a restored card
    /// keeps its identity instead of being minted a fresh UUID: the restored shell is
    /// re-opened carrying this same id as `SICH_CARD_ID`, which is what lets the
    /// hook feed bind an observed agent session back to the card and keep moving it
    /// between columns. Without it a restored card is frozen for the app's whole life.
    public let cardID: UUID?
    /// The column the card was parked in at quit. Persisted because a card's state is
    /// *detected*, not derived from the pane — nothing on the restore side could
    /// reconstruct it, so an unpersisted card always came back `.idle`, silently
    /// dropping a `waiting-for-input` ask.
    public let cardState: CardState?
    /// Whether the pane's process was alive **at snapshot time** — a fact recorded while
    /// we can still observe it, not inferred later. `childPID` is useless for this on the
    /// next launch: we SIGTERM every shell on the way out, so the recorded PID is dead by
    /// construction (and worse, may have been recycled onto an unrelated process). Only
    /// leaked SIGTERM-ignoring login shells made the old PID probe appear to work.
    /// Optional so a pre-`wasAlive` snapshot falls back to the PID probe.
    public let wasAlive: Bool?
    /// The remote session this pane was attached to, if any (US-006). Optional, so a
    /// pre-remote snapshot decodes it as nil and restores as the local pane it always
    /// was — the `claudeSessionID` precedent, and the reason this story needs no
    /// version bump (a bump is IGNORED, not migrated: it would discard every pane).
    /// A pane with one is rebuilt into an ssh/tmux argv on restore; `cwd` is then a
    /// label (`user@host`), not a local path.
    public let remote: RemoteSpecSnapshot?
    /// The Claude Code profile (`CLAUDE_CONFIG_DIR`) this pane's card uses. Optional
    /// for back-compat; nil means the default `~/.claude` account.
    public let claudeProfileID: UUID?

    public init(
        sessionID: UUID,
        cwd: String,
        agentType: AgentType,
        flowTag: FlowTag,
        childPID: Int32?,
        claudeSessionID: UUID? = nil,
        title: String? = nil,
        taskFolder: String? = nil,
        cardID: UUID? = nil,
        cardState: CardState? = nil,
        wasAlive: Bool? = nil,
        remote: RemoteSpecSnapshot? = nil,
        claudeProfileID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.agentType = agentType
        self.flowTag = flowTag
        self.childPID = childPID
        self.claudeSessionID = claudeSessionID
        self.title = title
        self.taskFolder = taskFolder
        self.cardID = cardID
        self.cardState = cardState
        self.wasAlive = wasAlive
        self.remote = remote
        self.claudeProfileID = claudeProfileID
    }

    /// The same pane with its app-level card metadata filled in. Core builds a pane from
    /// the session (which has no card notion); the app layer joins the card in by PTY
    /// identity and stamps what only it knows — the card's id, name, column, and folder.
    public func with(
        cardID: UUID?, cardState: CardState?, title: String?, taskFolder: String?,
        claudeProfileID: UUID? = nil
    ) -> PaneSnapshot {
        PaneSnapshot(
            sessionID: sessionID, cwd: cwd, agentType: agentType, flowTag: flowTag,
            childPID: childPID, claudeSessionID: claudeSessionID,
            title: title, taskFolder: taskFolder,
            cardID: cardID, cardState: cardState, wasAlive: wasAlive, remote: remote,
            claudeProfileID: claudeProfileID ?? self.claudeProfileID
        )
    }
}

/// How a pane came back on restore.
public enum PaneLiveness: String, Codable, Equatable, Sendable {
    /// A fresh shell/pane was re-opened at the pane's cwd — the normal case, and
    /// the only case for a pane whose recorded process was still alive.
    case reopened
    /// The pane's underlying process was gone → restored closed/dead, not
    /// live-frozen (US-003 edge case 3). No shell is re-opened for it.
    case dead
}

/// The outcome of restoring one pane: its original identity, the resolved cwd
/// (the home fallback when the original directory is gone), and whether it came
/// back live-reopened or closed/dead.
public struct RestoredPane: Equatable, Sendable {
    public let snapshot: PaneSnapshot
    public let cwd: String
    public let cwdFellBackToHome: Bool
    public let liveness: PaneLiveness

    public init(
        snapshot: PaneSnapshot,
        cwd: String,
        cwdFellBackToHome: Bool,
        liveness: PaneLiveness
    ) {
        self.snapshot = snapshot
        self.cwd = cwd
        self.cwdFellBackToHome = cwdFellBackToHome
        self.liveness = liveness
    }
}
