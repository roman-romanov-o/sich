import AppKit
import Testing
@testable import SichApp
import SichCore

/// Proves the remote-tmux card is actually reachable: `createRemoteTmuxSession`
/// (the method the ⌘⇧R menu action calls) builds a firewall-clean ssh card and
/// drops it on the board. Uses the reserved `.invalid` TLD so the spawned ssh fails
/// its lookup immediately instead of dialling a real host — the card is appended
/// synchronously, before ssh does anything, so the assertions don't race the process.
@MainActor
@Suite("Remote tmux card creation")
struct RemoteTmuxCardTests {

    @Test("createRemoteTmuxSession appends an ssh/tmux card on the board")
    func opensRemoteCard() throws {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        let spec = try #require(RemoteTmuxSpec.parse(
            destination: "roman@host.invalid:2200", sessionName: "agent"))
        let card = try #require(shell.createRemoteTmuxSession(spec: spec))

        #expect(shell.cards.contains { $0.id == card.id })
        #expect(card.projectDir == "roman@host.invalid")   // ssh destination, shown as the label
        #expect(card.sessionID == "remote/host.invalid/agent")
        #expect(card.flow == .b)
    }

    @Test("the launched command is ssh attaching to tmux — never claude -p")
    func remoteCommandIsFirewallClean() throws {
        let spec = RemoteTmuxSpec(host: "host.invalid", sessionName: "agent")
        let seed = try BoardSeed.remoteTmux(spec: spec)
        let remote = try #require(seed.command.last)
        #expect(seed.command.first == "/usr/bin/ssh")
        #expect(remote.hasPrefix("tmux new-session -A -s 'agent' "))
        #expect(try PoolFirewall.classify(seed.command) == .interactive)
    }

    /// US-004.AC-1 at the wiring seam: the seed's card id and the id the PANE
    /// exports must be the SAME string. A seed that mints one id for the card and
    /// drops it from the argv leaves every relayed hook pointing at nothing.
    @Test("the seed's card id is the id the pane exports")
    func seedBindsItsOwnCardID() throws {
        let seed = try BoardSeed.remoteTmux(
            spec: RemoteTmuxSpec(host: "host.invalid", sessionName: "agent"))
        let cardID = try #require(seed.cardID)
        let remote = try #require(seed.command.last)
        #expect(remote.contains("tmux set-environment SICH_CARD_ID \(cardID);"))
        #expect(remote.contains("SICH_CARD_ID=\(cardID) exec $SHELL -il"))
    }

    // MARK: - US-004.AC-1 — a remote card moves on relayed hooks, read side untouched

    /// The whole join, end to end and in the production order: ⌘⇧R's own
    /// `createRemoteTmuxSession` mints the card id and puts it in the pane's argv, a
    /// relay carries hook lines stamped with that id back, and `BoardShell.applySessions`
    /// — unchanged, still matching `boundCardID == card.id.uuidString` — moves the card.
    ///
    /// The sink below is the same one `startSessionsBridge` installs (BoardShell.swift:
    /// `sink: { cards in self?.applySessions(cards) }`), so this exercises the shipped
    /// wiring rather than a test-only path.
    @Test("TC-E2E-001 / AC-1: relayed hooks move a remote card by its SICH_CARD_ID")
    func remoteCardMovesOnRelayedHooks() async throws {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        // Capture the argv the card is actually launched with (and keep the spawn a
        // `/bin/cat`, not a real ssh), so the id the far side reports back is read off
        // THE PANE, never off the card object — otherwise a seed that minted two
        // different ids would still pass.
        let launched = LaunchedCommand()
        shell.launchOverrideForTesting = { seed in
            launched.set(seed.command)
            let pty = try! PTYSession(command: ["/bin/cat"])
            try! pty.start()
            return Session(projectDir: seed.projectDir, agentType: .claude,
                           flowTag: .interactive, pty: pty, state: .running)
        }

        let spec = RemoteTmuxSpec(host: "far.invalid", user: "roman", sessionName: "agent")
        let card = try #require(shell.createRemoteTmuxSession(spec: spec))
        let exported = try #require(Self.exportedCardID(in: launched.argv))
        #expect(exported == card.id.uuidString,
                "the pane exports the card's own id, or no hook can ever find it")

        let far = try RelayHost(
            host: "far.invalid", sessionID: "far-side-session-1", cardID: exported)
        defer { far.tearDown() }
        try far.write([])

        let local = try LocalSink()
        defer { local.tearDown() }
        try local.seed(#"{"hook_event_name":"SessionStart","session_id":"local-1"}"#)

        let board = CardBox()
        let poller = SessionsPoller(eventsFile: local.file, interval: 86_400) { cards in
            shell.applySessions(cards)
            board.set(shell.cards)
        }
        poller.start()
        await poller.drainForTesting()
        poller.attachRemoteHost(far.spec, transport: far.transport)
        defer { poller.stop() }

        try far.append(far.hook("UserPromptSubmit"))
        #expect(await waitUntil { board.cards.first { $0.id == card.id }?.state == .running })

        try far.append(far.hook("Stop"))
        #expect(await waitUntil {
            board.cards.first { $0.id == card.id }?.state == .waitingForInput
        })
        // No stray card: the observed session bound to the one we opened.
        #expect(shell.cards.count == 1)

        // DONE stays the operator's word (CARD-STATUS.md rule 4): the manual move
        // sticks, and a later relayed line does not reopen the card.
        shell.move(cardID: card.id, to: .done)
        try far.append(far.hook("UserPromptSubmit"))
        #expect(await waitUntil { board.cards.contains { $0.id == card.id } })
        #expect(shell.cards.first { $0.id == card.id }?.state == .done)
    }

    /// The value the pane's `tmux set-environment SICH_CARD_ID <id>` actually exports.
    private static func exportedCardID(in argv: [String]) -> String? {
        guard let remote = argv.last,
              let range = remote.range(of: "set-environment \(RemoteTmuxCommand.cardIDVariable) ")
        else { return nil }
        return remote[range.upperBound...].prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - US-004.AC-4 — (host, sanitized session name) is unique across cards

    @Test("a second card cannot claim a session name a card already holds")
    func duplicateSessionNameIsRefused() throws {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        let spec = RemoteTmuxSpec(host: "host.invalid", sessionName: "agent")
        #expect(shell.createRemoteTmuxSession(spec: spec) != nil)
        // -A ATTACHES, so a second card with this name would not be a second session:
        // both cards would drive (and be driven by) the same remote shell.
        #expect(shell.createRemoteTmuxSession(spec: spec) == nil)
        #expect(shell.lastRemoteSessionIssue
            == .duplicateCard(RemoteSessionKey(host: "host.invalid", session: "agent")))
        #expect(shell.cards.count == 1)
    }

    @Test("uniqueness is over the SANITIZED name — 'my.proj' and 'my proj' collide")
    func lossySanitisationCannotHideACollision() throws {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        #expect(shell.createRemoteTmuxSession(
            spec: RemoteTmuxSpec(host: "host.invalid", sessionName: "my.proj")) != nil)
        #expect(shell.createRemoteTmuxSession(
            spec: RemoteTmuxSpec(host: "host.invalid", sessionName: "my proj")) == nil)
        #expect(shell.cards.count == 1)
    }

    @Test("the same session name on ANOTHER host is a different session")
    func sameNameOnAnotherHostIsAllowed() throws {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        #expect(shell.createRemoteTmuxSession(
            spec: RemoteTmuxSpec(host: "one.invalid", sessionName: "agent")) != nil)
        #expect(shell.createRemoteTmuxSession(
            spec: RemoteTmuxSpec(host: "two.invalid", sessionName: "agent")) != nil)
        #expect(shell.cards.count == 2)
    }

    @Test("a blank session name gets a PER-CARD name, so two blank cards coexist")
    func blankSessionNameIsDerivedPerCard() throws {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        let first = try #require(shell.createRemoteTmuxSession(
            spec: RemoteTmuxSpec(host: "host.invalid", sessionName: "")))
        let second = try #require(shell.createRemoteTmuxSession(
            spec: RemoteTmuxSpec(host: "host.invalid", sessionName: "  ")))
        // The old constant default ("sich") made every unnamed card ONE session.
        #expect(first.sessionID == "remote/host.invalid/"
            + RemoteTmuxCommand.defaultSessionName(for: first.id))
        #expect(first.sessionID != second.sessionID)
        #expect(shell.cards.count == 2)
    }

    /// The far side is the other half of AC-4: a session Sich did not create makes
    /// `-A` ignore the command argument entirely, so `set-environment` never runs.
    @Test("a foreign session on the far side is surfaced, not bound silently")
    func foreignRemoteSessionIsSurfaced() throws {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        let spec = RemoteTmuxSpec(host: "host.invalid", sessionName: "agent")
        shell.remoteSessionRunner = StubSessionRunner(output: "SICH_CARD_ID=someone-elses-id")
        #expect(shell.createRemoteTmuxSession(spec: spec) == nil)
        #expect(shell.lastRemoteSessionIssue
            == .foreignSession(RemoteSessionKey(host: "host.invalid", session: "agent")))
        #expect(shell.cards.isEmpty)
    }

    @Test("an unreachable probe never blocks the card — unknown is not foreign")
    func unknownProbeStillOpensTheCard() throws {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        // The default runner refuses to spawn under `swift test`, so the probe answers
        // nothing at all. Refusing the card on silence would make remote cards unusable.
        #expect(shell.createRemoteTmuxSession(
            spec: RemoteTmuxSpec(host: "host.invalid", sessionName: "agent")) != nil)
        #expect(shell.lastRemoteSessionIssue == nil)
    }

    /// US-001.AC-2 at the call site the ⌘⇧R menu action actually reaches: the
    /// destination guard is not merely a unit-testable helper, it is the only way
    /// a remote card gets an argv, so an option-shaped host cannot become a card.
    @Test("an option-shaped destination cannot become a card")
    func optionShapedDestinationMakesNoCard() throws {
        let shell = BoardShell(seeds: [])
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        let payload = "-oProxyCommand=sh -c 'claude -p x'"
        let spec = try #require(RemoteTmuxSpec.parse(destination: payload, sessionName: "agent"))
        #expect(throws: RemoteTmuxCommand.Invalid.invalidDestination(payload)) {
            try BoardSeed.remoteTmux(spec: spec)
        }
        #expect(shell.createRemoteTmuxSession(spec: spec) == nil)
        #expect(shell.cards.isEmpty)
    }
}

/// The argv a card was really launched with, captured at the launch seam.
private final class LaunchedCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var command: [String] = []

    func set(_ argv: [String]) {
        lock.lock()
        command = argv
        lock.unlock()
    }

    var argv: [String] {
        lock.lock()
        defer { lock.unlock() }
        return command
    }
}

/// A far side that answers the session probe without any ssh.
private struct StubSessionRunner: RemoteCommandRunner {
    let output: String

    func run(argv: [String], input: Data?) -> RemoteCommandResult? {
        RemoteCommandResult(exitCode: 0, standardOutput: Data(output.utf8))
    }
}
