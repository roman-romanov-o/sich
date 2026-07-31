import Foundation
import Testing

@testable import SichCore

/// US-006 at the core seam: what a remote pane PERSISTS, and what the restorer
/// rebuilds from it.
///
/// The shipped bug this suite pins: a remote pane persists `cwd = "roman@host"`
/// (a label, not a path), so `resolveCwd` finds no such directory, falls back to
/// `$HOME`, and the restorer hands back a LOCAL `$SHELL` — the card comes back
/// looking remote and behaving local.
@Suite("Remote pane restore (US-006)")
struct RemotePaneRestoreTests {

    private static let cardID = UUID(uuidString: "6E7B0C1A-0000-4000-8000-000000000001")!

    private func remotePane(
        spec: RemoteTmuxSpec, cardID: UUID = RemotePaneRestoreTests.cardID
    ) -> PaneSnapshot {
        PaneSnapshot(
            sessionID: UUID(), cwd: spec.target, agentType: .claude, flowTag: .interactive,
            childPID: 4242, cardID: cardID, wasAlive: true,
            remote: RemoteSpecSnapshot(spec: spec)
        )
    }

    /// A restorer that records the argv it would launch. `directoryExists` answers the
    /// way production does for a remote card's label: "roman@host.invalid" is no
    /// directory, which is exactly what used to send the pane home as a local shell.
    private func spyRestorer(_ spy: @escaping ([String]) -> Void) -> SessionRestorer {
        SessionRestorer(
            isAlive: { _ in true },
            directoryExists: { $0.hasPrefix("/") },
            homeDirectory: "/Users/tester", shellPath: "/bin/zsh",
            reopen: { _, argv in spy(argv) }
        )
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-remote-restore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - AC-1 / AC-5 — the rebuild goes back to ssh, through the firewall

    @Test("AC-1: a restored remote pane reconnects over ssh, not a local shell")
    func remotePaneRebuildsItsSSHCommand() throws {
        let spec = RemoteTmuxSpec(host: "host.invalid", user: "roman", sessionName: "agent")
        var spawned: [[String]] = []
        let restorer = spyRestorer { spawned.append($0) }

        let restored = restorer.restore(SessionSnapshot(
            createdAt: Date(), windows: [WindowSnapshot(panes: [remotePane(spec: spec)])]))

        #expect(restored.first?.liveness == .reopened)
        // The bug: a local `/bin/sh -c "cd '/Users/tester' && … exec '/bin/zsh' -il"`.
        let argv = try #require(spawned.first)
        #expect(argv.first == "/usr/bin/ssh")
        #expect(try #require(argv.last).hasPrefix("tmux new-session -A -s 'agent'"))
        // …and the pane keeps its remote label instead of being sent home.
        #expect(restored.first?.cwd == "roman@host.invalid")
        #expect(restored.first?.cwdFellBackToHome == false)
    }

    @Test("AC-2: the rebuild goes through the SAME argv constructor the create path uses")
    func rebuildUsesTheSharedConstructor() throws {
        let spec = RemoteTmuxSpec(
            host: "host.invalid", user: "roman", sessionName: "agent",
            port: 2200, remoteDir: "/srv/app")
        var spawned: [[String]] = []
        let restorer = spyRestorer { spawned.append($0) }

        _ = restorer.restore(SessionSnapshot(
            createdAt: Date(), windows: [WindowSnapshot(panes: [remotePane(spec: spec)])]))

        #expect(spawned.first == (try RemoteTmuxCommand.argv(
            for: spec, cardID: Self.cardID.uuidString)))
    }

    @Test("AC-5: the rebuilt argv passes the pool firewall as interactive")
    func rebuiltArgvIsFirewallClean() throws {
        let spec = RemoteTmuxSpec(host: "host.invalid", user: "roman", sessionName: "agent")
        var spawned: [[String]] = []
        let restorer = spyRestorer { spawned.append($0) }

        _ = restorer.restore(SessionSnapshot(
            createdAt: Date(), windows: [WindowSnapshot(panes: [remotePane(spec: spec)])]))

        let argv = try #require(spawned.first)
        // The sharpest ssh call site there is: it runs AT LAUNCH, from data on disk,
        // with no human present — so the gate has to hold on THIS argv, not just on
        // the local shell it used to be handed.
        #expect(argv.first == "/usr/bin/ssh")
        #expect(try PoolFirewall.classify(argv) == .interactive)
        #expect(!argv.joined(separator: " ").contains("claude -p"))
    }

    @Test("AC-4: the rebuilt pane exports the card's ORIGINAL id, so telemetry rebinds")
    func rebuiltPaneExportsTheOriginalCardID() throws {
        let spec = RemoteTmuxSpec(host: "host.invalid", user: "roman", sessionName: "agent")
        var spawned: [[String]] = []
        let restorer = spyRestorer { spawned.append($0) }

        _ = restorer.restore(SessionSnapshot(
            createdAt: Date(), windows: [WindowSnapshot(panes: [remotePane(spec: spec)])]))

        let remote = try #require(spawned.first?.last)
        #expect(remote.contains("tmux set-environment SICH_CARD_ID \(Self.cardID.uuidString);"))
        #expect(remote.contains("SICH_CARD_ID=\(Self.cardID.uuidString) exec $SHELL -il"))
    }

    // MARK: - AC-2 — the persisted format cannot name a command

    @Test("AC-2: the persisted remote block holds the spec's fields and nothing else")
    func persistedRemoteBlockCannotNameACommand() throws {
        let spec = RemoteTmuxSpec(
            host: "host.invalid", user: "roman", sessionName: "agent",
            port: 2200, identityFile: "/Users/tester/.ssh/id_ed25519", remoteDir: "/srv/app")
        let data = try JSONEncoder().encode(remotePane(spec: spec))
        let pane = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let remote = try #require(pane["remote"] as? [String: Any])

        // Every field is a constrained *coordinate* of a session — none of them is,
        // or can hold, a command to run.
        #expect(Set(remote.keys)
            == ["host", "user", "sessionName", "port", "identityFile", "remoteDir"])
        // An argv is a LIST of words; every coordinate here is a single scalar, so the
        // shape itself refuses one.
        #expect(remote.values.allSatisfy { $0 is String || $0 is Int })
        let text = String(decoding: data, as: UTF8.self)
        for command in ["tmux", "exec", "new-session", "/bin/sh", "/usr/bin/", "claude -p"] {
            #expect(!text.contains(command), "the snapshot must not be able to name \(command)")
        }
    }

    @Test("AC-2: a persisted remote block round-trips back into the same spec")
    func remoteBlockRoundTrips() throws {
        let spec = RemoteTmuxSpec(
            host: "host.invalid", user: "roman", sessionName: "agent",
            port: 2200, identityFile: "/Users/tester/.ssh/id_ed25519", remoteDir: "/srv/app")
        let encoded = try JSONEncoder().encode(RemoteSpecSnapshot(spec: spec))
        let decoded = try JSONDecoder().decode(RemoteSpecSnapshot.self, from: encoded)
        #expect(decoded.spec == spec)
    }

    // MARK: - AC-3 — no version bump (a bump discards every user's panes)

    @Test("AC-3: an OLD snapshot with no remote field still loads at version 1")
    func oldSnapshotStillLoads() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionSnapshotStore(directory: dir)
        try Data(Self.legacySnapshotJSON(version: 1).utf8).write(to: store.currentURL)

        // A bump here would make every pre-upgrade snapshot decode to nil below.
        #expect(SessionSnapshot.currentVersion == 1)
        let snapshot = try #require(store.load())
        let pane = try #require(snapshot.windows.flatMap(\.panes).first)
        #expect(pane.remote == nil)
        #expect(pane.cwd == "/tmp")
    }

    /// Edge case 1: no `remote` field → an ordinary local pane, byte for byte the
    /// behaviour that shipped before this story.
    @Test("edge: a pane with no remote field restores as a local shell, unchanged")
    func paneWithoutRemoteFieldRestoresLocal() throws {
        var spawned: [[String]] = []
        let local = PaneSnapshot(
            sessionID: UUID(), cwd: "/tmp", agentType: .claude, flowTag: .interactive,
            childPID: 4242, wasAlive: true)
        let restored = spyRestorer { spawned.append($0) }.restore(
            SessionSnapshot(createdAt: Date(), windows: [WindowSnapshot(panes: [local])]))

        #expect(restored.count == 1)
        let argv = try #require(spawned.first)
        #expect(argv.first == "/bin/sh")
        #expect(try #require(argv.last).contains("cd '/tmp' &&"))
        #expect(try #require(argv.last).hasSuffix("exec '/bin/zsh' -il"))
    }

    @Test("AC-3: a version mismatch is IGNORED, never migrated")
    func versionMismatchIsIgnored() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionSnapshotStore(directory: dir)
        // This is why the shape must stay at v1: a bumped file yields NOTHING —
        // every pane the operator had open is discarded, not migrated.
        try Data(Self.legacySnapshotJSON(version: 2).utf8).write(to: store.currentURL)
        #expect(store.load() == nil)
    }

    // MARK: - Edge case 2 — an unusable destination drops the pane

    @Test("edge: a persisted host that fails the grammar DROPS the pane, never localises it")
    func ungrammaticalHostDropsThePane() throws {
        let payload = "-oProxyCommand=sh -c 'claude -p x'"
        let spec = try #require(RemoteTmuxSpec.parse(destination: payload, sessionName: "agent"))
        var spawned: [[String]] = []

        let restored = spyRestorer { spawned.append($0) }.restore(SessionSnapshot(
            createdAt: Date(), windows: [WindowSnapshot(panes: [remotePane(spec: spec)])]))

        // Falling back to a local shell IS the bug: it would silently run the
        // operator's shell where a remote session was promised.
        #expect(restored.isEmpty)
        #expect(spawned.isEmpty)
    }

    /// A v1 snapshot exactly as an older build wrote it: no `remote`, no field this
    /// story adds.
    private static func legacySnapshotJSON(version: Int) -> String {
        """
        {"createdAt":0,"version":\(version),"windows":[{"panes":[
        {"sessionID":"\(UUID().uuidString)","cwd":"/tmp","agentType":"claude",
        "flowTag":"interactive","childPID":4242,"wasAlive":true}]}]}
        """
    }
}
