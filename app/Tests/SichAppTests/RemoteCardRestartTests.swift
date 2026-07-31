import Foundation
import SichCore
import Testing

@testable import SichApp

/// US-006 / ts-e2e-02 — a remote card survives restart, driven through the REAL
/// quit→restart seams (`createRemoteTmuxSession` → `persistOnTerminate` →
/// `restoreCardsForTesting`), never the snapshot leaves directly.
///
/// The bug this pins: the seed persists `projectDir: spec.target`, so the pane's
/// `cwd` is the label "roman@host" — no such directory — and restore quietly
/// re-opened a LOCAL `$SHELL` in `$HOME` under a card still titled for the host.
///
/// No case dials a host: the reserved `.invalid` TLD fails its lookup immediately,
/// and every assertion is on the argv/snapshot, never on a connection.
@MainActor
@Suite(.serialized)
struct RemoteCardRestartTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-remote-restart-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A restorer that records what the wired path *would* launch, with production's own
    /// cwd probe semantics (a `user@host` label is not a directory).
    private func spyingRestorer(_ spy: @escaping ([String]) -> Void) -> SessionRestorer {
        SessionRestorer(
            isAlive: { _ in true }, directoryExists: { $0.hasPrefix("/") },
            homeDirectory: NSHomeDirectory(), shellPath: "/bin/zsh",
            reopen: { _, argv in spy(argv) })
    }

    /// The snapshot a quit writes for a remote card — asserted field-by-field by
    /// ``remoteCardPersistsItsSpec`` below, so the restore cases can start from it
    /// without depending on a real ssh child still being alive at snapshot time.
    private func remoteSnapshot(cardID: UUID, spec: RemoteTmuxSpec) -> SessionSnapshot {
        SessionSnapshot(createdAt: Date(), windows: [WindowSnapshot(panes: [PaneSnapshot(
            sessionID: UUID(), cwd: spec.target, agentType: .claude, flowTag: .interactive,
            childPID: 4242, title: "\(spec.target) · \(spec.sessionName)",
            cardID: cardID, cardState: .idle, wasAlive: true,
            remote: RemoteSpecSnapshot(spec: spec))])])
    }

    // MARK: - AC-2 — the quit path persists the SPEC

    @Test("AC-2: quitting persists the remote SPEC, and the file cannot name a command")
    func remoteCardPersistsItsSpec() throws {
        let storeDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        let spec = RemoteTmuxSpec(host: "host.invalid", user: "roman", sessionName: "agent")
        let card = try #require(shell.createRemoteTmuxSession(spec: spec))

        let store = SessionSnapshotStore(directory: storeDir)
        let saved = try #require(shell.persistOnTerminate(store: store))
        let pane = try #require(saved.windows.flatMap(\.panes).first)

        #expect(pane.cardID == card.id)
        #expect(pane.remote == RemoteSpecSnapshot(spec: spec))
        // The whole point of persisting the constructor's INPUT: nothing on disk is a
        // command, so nothing on disk can be replayed as one.
        let text = String(decoding: try Data(contentsOf: store.currentURL), as: UTF8.self)
        for command in ["tmux", "exec", "new-session", "/usr/bin/", "claude -p"] {
            #expect(!text.contains(command), "the snapshot must not be able to name \(command)")
        }
    }

    // MARK: - AC-1 / AC-5 — the restart reconnects over ssh

    @Test("AC-1: a restored remote pane re-attaches its tmux session over ssh")
    func restoredRemotePaneReattaches() throws {
        let storeDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let cardID = UUID()
        let spec = RemoteTmuxSpec(host: "host.invalid", user: "roman", sessionName: "agent")
        let store = SessionSnapshotStore(directory: storeDir)
        try store.save(remoteSnapshot(cardID: cardID, spec: spec))

        var spawned: [[String]] = []
        let relaunched = BoardShell()
        defer { relaunched.e2eTeardown() }
        _ = relaunched.restoreOnLaunch(
            store: store, restorer: spyingRestorer { spawned.append($0) })

        let argv = try #require(spawned.first)
        // Shipped behaviour was `/bin/sh -c "cd '$HOME' && … exec '/bin/zsh' -il"`.
        #expect(argv == (try RemoteTmuxCommand.argv(for: spec, cardID: cardID.uuidString)))
        // AC-5: this runs at launch, from a file, with nobody watching.
        #expect(try PoolFirewall.classify(argv) == .interactive)
    }

    @Test("AC-1: the restored CARD is the remote one, not a local shell wearing its name")
    func restoredCardIsRemote() throws {
        let storeDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let cardID = UUID()
        let spec = RemoteTmuxSpec(host: "host.invalid", user: "roman", sessionName: "agent")
        let store = SessionSnapshotStore(directory: storeDir)
        try store.save(remoteSnapshot(cardID: cardID, spec: spec))

        let relaunched = BoardShell()
        defer { relaunched.e2eTeardown() }
        let cards = relaunched.restoreCardsForTesting(store: store)

        let card = try #require(cards.first)
        #expect(card.id == cardID)
        // The label the operator recognises — not NSHomeDirectory().
        #expect(card.projectDir == "roman@host.invalid")
        #expect(card.projectDir != NSHomeDirectory())
        // …and the board still knows which remote session this card holds, so a second
        // card cannot claim the same one.
        #expect(card.sessionID == "remote/host.invalid/agent")
        #expect(relaunched.createRemoteTmuxSession(spec: spec) == nil)
    }

    /// A remote pane comes back by ATTACHING; tmux kept the far-side session exactly as
    /// it was. Typing `claude --resume` into it would talk over whatever is already
    /// running there.
    @Test("a restored remote pane is not fed agent keystrokes")
    func restoredRemotePaneSendsNoAgentCommand() throws {
        let spec = RemoteTmuxSpec(host: "host.invalid", user: "roman", sessionName: "agent")
        let pane = PaneSnapshot(
            sessionID: UUID(), cwd: spec.target, agentType: .claude, flowTag: .interactive,
            childPID: 4242, wasAlive: true, remote: RemoteSpecSnapshot(spec: spec))
        #expect(BoardShell.restoredAgentCommand(for: pane) == nil)
        // The local pane it is derived from still resumes — this is a remote carve-out,
        // not a regression of the resume feature.
        let local = PaneSnapshot(
            sessionID: UUID(), cwd: "/tmp", agentType: .claude, flowTag: .interactive,
            childPID: 4242, wasAlive: true)
        #expect(BoardShell.restoredAgentCommand(for: local) != nil)
    }

    // MARK: - AC-4 — the restored card rebinds to its telemetry

    @Test("AC-4: a hook relayed after the restart lands on the RESTORED card")
    func restoredRemoteCardRebindsToTelemetry() async throws {
        let storeDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let cardID = UUID()
        let spec = RemoteTmuxSpec(host: "far.invalid", user: "roman", sessionName: "agent")
        let store = SessionSnapshotStore(directory: storeDir)
        try store.save(remoteSnapshot(cardID: cardID, spec: spec))

        let relaunched = BoardShell()
        defer { relaunched.e2eTeardown() }
        let card = try #require(relaunched.restoreCardsForTesting(store: store).first)

        let far = try RelayHost(
            host: "far.invalid", sessionID: "far-side-session-restart",
            cardID: cardID.uuidString)
        defer { far.tearDown() }
        try far.write([])

        let local = try LocalSink()
        defer { local.tearDown() }
        try local.seed(#"{"hook_event_name":"SessionStart","session_id":"local-1"}"#)

        let board = CardBox()
        let poller = SessionsPoller(eventsFile: local.file, interval: 86_400) { cards in
            relaunched.applySessions(cards)
            board.set(relaunched.cards)
        }
        poller.start()
        await poller.drainForTesting()
        poller.attachRemoteHost(far.spec, transport: far.transport)
        defer { poller.stop() }

        // The restored card is OBSERVED, not an unbound terminal: the far side stamps
        // the id the rebuilt argv exported, which is the id the card kept.
        try far.append(far.hook("UserPromptSubmit"))
        #expect(await waitUntil { board.cards.first { $0.id == card.id }?.state == .running })
        #expect(relaunched.cards.count == 1, "no stray card — the hook bound to the restored one")
    }

    /// The case above proves the restored card *can* receive telemetry once someone
    /// follows the host — but the test itself did the following. This one holds the
    /// production seam: restoring must make the board's OWN poller follow the host,
    /// or a restarted remote card is an unobserved terminal that never moves again.
    @Test("AC-4: restoring makes the board itself follow the host's event log")
    func restoreAttachesTheBoardsOwnRelay() throws {
        let storeDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let spec = RemoteTmuxSpec(host: "far.invalid", user: "roman", sessionName: "agent")
        let store = SessionSnapshotStore(directory: storeDir)
        try store.save(remoteSnapshot(cardID: UUID(), spec: spec))

        let local = try LocalSink()
        defer { local.tearDown() }
        try local.seed("")
        let relaunched = BoardShell()
        defer { relaunched.e2eTeardown() }
        let poller = SessionsPoller(eventsFile: local.file, interval: 86_400) { _ in }
        relaunched.sessionsPoller = poller
        defer { poller.stop() }

        #expect(poller.relayHealth(for: "far.invalid") == nil, "nothing followed yet")
        _ = relaunched.restoreCardsForTesting(store: store)
        // No connection is made (transport spawning is off under test) — what is asserted
        // is that the board *asked* to follow this host, from data on disk, unprompted.
        #expect(poller.relayHealth(for: "far.invalid") != nil)
    }
}
