import Foundation
import SichCore
import Testing

@testable import SichApp

/// Checklist "resume the remote session doesn't work" — the TASK-BOOK path.
/// The snapshot path (quit → restart) already revives remote cards
/// (``RemoteCardRestartTests``); this suite pins the two ways a remote card used
/// to die for good:
///
///  1. The book resurrected it as a session-less card whose `projectDir` is the
///     `user@host` label — `reviveSession`'s local-dir guard made every click
///     inert, so the card was a tombstone.
///  2. A dropped ssh link (laptop slept, wifi changed) reaped the child and
///     `removeDeadCard` DELETED the card — while tmux kept the far side running.
///
/// No case dials a host: the reserved `.invalid` TLD fails its lookup
/// immediately; assertions are on argv/state, never on a connection.
@MainActor
@Suite(.serialized)
struct RemoteCardReviveTests {

    private let spec = RemoteTmuxSpec(host: "host.invalid", user: "roman", sessionName: "agent")

    private func makeTempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-remote-revive-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The launch seam: keep the spawn a `/bin/cat` (never a real ssh) while
    /// capturing the argv and the Session the shell would have driven.
    private func stubLaunches(on shell: BoardShell, into box: LaunchBox) {
        shell.launchOverrideForTesting = { seed in
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            let session = Session(projectDir: seed.projectDir, agentType: .claude,
                                  pty: pty, state: .running)
            box.record(argv: seed.command, session: session)
            return session
        }
    }

    // MARK: - 1. the task book carries the spec, and drill-in re-attaches from it

    @Test("a remote task adopted from the task book revives by re-attaching over ssh")
    func adoptedRemoteTaskRevivesByReattach() throws {
        let bookDir = makeTempDir("book")
        let snapDir = makeTempDir("snap")
        defer {
            try? FileManager.default.removeItem(at: bookDir)
            try? FileManager.default.removeItem(at: snapDir)
        }

        // Session 1: create the remote card with the book wired in.
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        shell.taskStore = BoardTaskStore(directory: bookDir)
        stubLaunches(on: shell, into: LaunchBox())
        let card = try #require(shell.createRemoteTmuxSession(spec: spec))
        shell.e2eTeardown()

        // The book persisted the constructor's INPUT — the spec, never an argv.
        let record = try #require(
            BoardTaskStore(directory: bookDir).load()?.tasks.first { $0.id == card.id })
        #expect(record.remote == RemoteSpecSnapshot(spec: spec))

        // Session 2: the shell is gone (no snapshot); only the book brings the task back.
        let relaunched = BoardShell()
        defer { relaunched.e2eTeardown() }
        _ = relaunched.buildContentForTesting()
        relaunched.taskStore = BoardTaskStore(directory: bookDir)
        relaunched.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: snapDir))

        let revived = try #require(relaunched.cards.first { $0.id == card.id })
        // The `(host, session)` id — what the duplicate guard and host chip read —
        // survives adoption; a bare UUID here would let a second card claim the session.
        #expect(revived.sessionID == "remote/host.invalid/agent")
        #expect(revived.projectDir == "roman@host.invalid")
        #expect(relaunched.ptyForTesting(revived.id) == nil, "session-less until drilled into")

        // Drill-in: the click must NOT be inert (the shipped bug) — it re-attaches
        // with the ORIGINAL card id so far-side hooks keep binding to this card.
        let box = LaunchBox()
        stubLaunches(on: relaunched, into: box)
        relaunched.drill(into: revived)
        #expect(box.argv == (try RemoteTmuxCommand.argv(for: spec, cardID: card.id.uuidString)))
        #expect(relaunched.ptyForTesting(revived.id) != nil)
        // Re-attach only: tmux kept the far side as the operator left it, so no
        // resume keystrokes — the local revive path would have pinned a Claude id.
        #expect(box.session?.claudeSessionID == nil)
        #expect(box.session?.remoteSpec == spec, "the revived session carries its spec forward")
    }

    @Test("reviving makes the board's own poller follow the host's event log again")
    func revivalAttachesTheBoardsOwnRelay() throws {
        let bookDir = makeTempDir("relay")
        let snapDir = makeTempDir("relay-snap")
        defer {
            try? FileManager.default.removeItem(at: bookDir)
            try? FileManager.default.removeItem(at: snapDir)
        }
        let store = BoardTaskStore(directory: bookDir)
        let record = TaskRecord(
            title: "far work", placement: .board(.idle), projectDir: spec.target,
            remote: RemoteSpecSnapshot(spec: spec))
        _ = try store.save(tasks: [record])

        let local = try LocalSink()
        defer { local.tearDown() }
        try local.seed("")
        let shell = BoardShell()
        defer { shell.e2eTeardown() }
        _ = shell.buildContentForTesting()
        shell.taskStore = store
        let poller = SessionsPoller(eventsFile: local.file, interval: 86_400) { _ in }
        shell.sessionsPoller = poller
        defer { poller.stop() }
        shell.hydrateForTesting(sessionStore: SessionSnapshotStore(directory: snapDir))

        #expect(poller.relayHealth(for: "host.invalid") == nil, "nothing followed yet")
        let revived = try #require(shell.cards.first { $0.id == record.id })
        stubLaunches(on: shell, into: LaunchBox())
        shell.drill(into: revived)
        // Without this, the revived card is an unobserved terminal that never moves.
        #expect(poller.relayHealth(for: "host.invalid") != nil)
    }

    // MARK: - 2. a dropped ssh link demotes the card, never deletes it

    @Test("a dead ssh child keeps the remote card — idle, ready to re-attach")
    func deadSshLinkDemotesInsteadOfDeleting() throws {
        let shell = BoardShell(seeds: [])
        defer { shell.e2eTeardown() }
        _ = shell.buildContentForTesting()

        // REAL spawn path: ssh to the reserved `.invalid` TLD fails its lookup and
        // exits — exactly what a dropped link looks like to the reconcile loop.
        let card = try #require(shell.createRemoteTmuxSession(spec: spec))
        reconcileUntilProcessed(shell)

        // tmux still holds the far side: the task is NOT over, only the link is.
        let kept = try #require(shell.cards.first { $0.id == card.id })
        #expect(kept.state == .idle)
        #expect(shell.ptyForTesting(card.id) == nil, "the dead fd is closed")

        // The next drill-in re-attaches the SAME far-side session under the same id.
        let box = LaunchBox()
        stubLaunches(on: shell, into: box)
        shell.drill(into: kept)
        #expect(box.argv == (try RemoteTmuxCommand.argv(for: spec, cardID: card.id.uuidString)))
        #expect(shell.ptyForTesting(card.id) != nil)
    }

    /// Poll the reconcile pass until the exited child is reaped (bounded).
    private func reconcileUntilProcessed(_ shell: BoardShell) {
        for _ in 0..<500 {
            if !shell.reconcileDeadSessions().isEmpty { return }
            usleep(10_000)
        }
    }
}

/// The argv + Session a revival really launched, captured at the launch seam.
private final class LaunchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedArgv: [String] = []
    private var capturedSession: Session?

    func record(argv: [String], session: Session) {
        lock.lock()
        capturedArgv = argv
        capturedSession = session
        lock.unlock()
    }

    var argv: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedArgv
    }

    var session: Session? {
        lock.lock()
        defer { lock.unlock() }
        return capturedSession
    }
}
