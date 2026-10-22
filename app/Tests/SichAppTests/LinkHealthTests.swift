import AppKit
import Foundation
import Testing

@testable import SichApp
@testable import SichCore

/// US-007 — a dead connection is visible (ts-e2e-04, ts-int-03).
///
/// The defect these exist against is a card that keeps reading `running` after the
/// machine it runs on stopped answering: the operator reads a frozen state as
/// progress. So the load-bearing assertions here are NEGATIVE — not "some flag
/// flipped" but "the card no longer reads `running`, and no longer reads `waiting`
/// either".
///
/// Two rules this file obeys, borrowed from ``HostChipRenderTests``:
///  * the render assertions read the mounted view's own state (its text, its
///    colour, its class) rather than a bitmap. `cacheDisplay`/`CALayer.render` do
///    not faithfully composite AppKit layers, so a capture would be non-evidence —
///    which is why the marker is a custom-drawn ``LinkChip`` and not a stock control;
///  * every card goes through the board's real path (`createRemoteTmuxSession` →
///    `SessionsPoller` → `applySessions` → `boardView.render`), because
///    green-but-unreachable is this repo's classic false pass.
///
/// No test dials a host: destinations are in the reserved `.invalid` TLD and the ssh
/// child is replaced by an in-memory ``ReconnectTransport`` the test drives itself.
@MainActor
@Suite(.serialized)
struct LinkHealthTests {

    // MARK: - AC-1: the child exits, and the board says so within one poll

    /// TC-E2E-005. The whole story in one pass: the card earns a real `running` from
    /// relayed hook lines, the ssh child dies, and one board poll later the card reads
    /// `unreachable` instead.
    @Test("AC-1/AC-3: a dead ssh child turns a running card unreachable, not frozen")
    func aDeadChildTurnsARunningCardUnreachable() async throws {
        let rig = try await Rig(host: "dead.invalid")
        defer { rig.tearDown() }

        try await rig.driveToRunning()
        #expect(rig.rendered()?.card.state == .running, "precondition: a live remote card works")

        // Detection: the child's exit IS the signal. Nothing is awaited here — on this
        // path there is no keepalive delay to wait out (AC-1).
        rig.transport.finish(RemoteEventRelay.sshFailureExit)
        #expect(rig.poller.relayHealth(for: rig.host) == .unreachable)

        // Propagation: one board poll cycle, driven deterministically through the same
        // handler the FS watch fires.
        await rig.pollBoardOnce()

        let shown = try #require(rig.rendered()?.card.state)
        #expect(shown == .unreachable)
        // The negative, which is the point of the story.
        #expect(shown != .running, "a card on a dead host must not keep reading running")
        #expect(shown != .waitingForInput)
    }

    /// Two tailnets: a host on the one you are not on right now reads as a dead link.
    /// Finished work there must stay in DONE, not be dragged back into PARKED as
    /// `unreachable` — completion is settled and nothing remote can change it.
    @Test("a DONE card on a dead host stays done")
    func aDoneCardOnADeadHostStaysDone() async throws {
        let rig = try await Rig(host: "othernet.invalid")
        defer { rig.tearDown() }
        try await rig.driveToRunning()
        rig.shell.move(cardID: rig.card.id, to: .done)

        rig.transport.finish(RemoteEventRelay.sshFailureExit)
        #expect(rig.poller.relayHealth(for: rig.host) == .unreachable)
        await rig.pollBoardOnce()

        let shown = try #require(rig.shell.displayCards().first { $0.id == rig.card.id })
        #expect(shown.state == .done)
        #expect(BoardView.ColumnGroup.group(for: shown.state) == .done)
    }

    /// X and the detection latency are different quantities (AC-2 says so explicitly);
    /// this asserts X alone. X is what the BOARD costs — one sessions-poll backstop
    /// cycle, which runs whether or not a single event line arrived.
    @Test("AC-1: X — the board's own delay is bounded at 5s")
    func theBoardsShareOfTheDelayIsOnePollCycle() {
        #expect(BoardShell.unreachableVisibleWithin == 5)
        #expect(SessionsPoller.defaultInterval <= BoardShell.unreachableVisibleWithin,
                "every backstop tick pushes cards, so the poll cadence IS the board's bound")
    }

    // MARK: - AC-2: a silent partition reaches the same state, on the keepalive budget

    /// TC-INT-004. A partition sends no exit — ssh has to notice by itself, which it
    /// only does because the relay argv asks it to.
    @Test("AC-2: the relay argv carries the keepalives that make a partition detectable")
    func theRelayArgvAsksSshToNoticeASilentPartition() throws {
        let argv = try RemoteTmuxCommand.relayArgv(
            for: RemoteTmuxSpec(host: "partition.invalid", user: "roman"))

        #expect(argv.contains("ServerAliveInterval=15"))
        #expect(argv.contains("ServerAliveCountMax=3"))
        // Read the budget back out of the argv rather than off a constant, so the test
        // measures what ssh is actually told.
        #expect(Self.keepaliveBudget(in: argv) == 45)
    }

    /// The two latencies are distinct and are asserted apart: ~45s is how long
    /// DETECTION may take on a silent partition; 5s is how long the BOARD then takes.
    /// Conflating them was the trap the AC calls out.
    @Test("AC-2: detection latency and X are separate quantities")
    func detectionLatencyIsNotTheBoardsDelay() throws {
        let argv = try RemoteTmuxCommand.relayArgv(
            for: RemoteTmuxSpec(host: "partition.invalid", user: "roman"))
        let detection = Self.keepaliveBudget(in: argv)

        #expect(detection == 45)
        #expect(BoardShell.unreachableVisibleWithin == 5)
        #expect(detection > BoardShell.unreachableVisibleWithin,
                "a partition is noticed on ssh's clock, then rendered on the board's")
    }

    /// A keepalive timeout is delivered as ssh's own 255 — the SAME transition an
    /// outright child exit takes, which is why one code path serves both.
    @Test("AC-2: a keepalive timeout reaches unreachable by the same path")
    func aKeepaliveTimeoutTakesTheSameTransition() async throws {
        let rig = try await Rig(host: "wedged.invalid")
        defer { rig.tearDown() }
        try await rig.driveToRunning()

        rig.transport.finish(RemoteEventRelay.sshFailureExit)   // ssh gave up on the link
        await rig.pollBoardOnce()

        #expect(rig.rendered()?.card.state == .unreachable)
    }

    /// TC-INT-002's other half. ssh returns the REMOTE command's status when the host
    /// answered, so a missing log (tail exits 1) is silence, not a dead link.
    @Test("AC-2: a remote command failure is not a dead link")
    func aRemoteCommandFailureIsNotADeadLink() async throws {
        let rig = try await Rig(host: "quiet.invalid")
        defer { rig.tearDown() }
        try await rig.driveToRunning()

        rig.transport.finish(1)   // `tail: cannot open …` — the host answered
        await rig.pollBoardOnce()

        #expect(rig.poller.relayHealth(for: rig.host) != .unreachable)
        #expect(rig.rendered()?.card.state == .running)
    }

    // MARK: - AC-3: the negative, on every surface that reads a state

    @Test("AC-3: unreachable is a distinct state that is neither working nor attention")
    func unreachableIsNeitherWorkingNorAttention() {
        #expect(CardState.unreachable != .running)
        #expect(CardState.unreachable != .waitingForInput)
        #expect(CardState.unreachable != .unknown)
        #expect(CardState.unreachable != .done)
        #expect(!CardState.unreachable.isWorking)
        #expect(!CardState.unreachable.needsAttention, "a dead host is not an agent asking for you")
        #expect(BoardView.ColumnGroup.group(for: .unreachable) != .working)
        #expect(BoardView.ColumnGroup.group(for: .unreachable) != .needsYou)
        #expect(BoardColumn(state: .unreachable) != .running)
        #expect(AgentTaskTally.tally([Self.card(state: .unreachable)]).isEmpty,
                "unreachable work is not in-progress work — the pool load must not count it")
    }

    /// A card that WAS waiting on you when the link died must stop saying so: after
    /// the partition we no longer know that it still is.
    @Test("AC-3: a waiting card on a dead host stops reading waiting")
    func aWaitingCardOnADeadHostStopsReadingWaiting() async throws {
        let rig = try await Rig(host: "waiting.invalid")
        defer { rig.tearDown() }
        try await rig.driveToRunning()
        try await rig.drive(events: ["Stop"], until: .waitingForInput)
        #expect(rig.attentionCount() == 1, "precondition: it really was asking for you")

        rig.transport.finish(RemoteEventRelay.sshFailureExit)
        await rig.pollBoardOnce()

        let shown = try #require(rig.rendered()?.card.state)
        #expect(shown == .unreachable)
        #expect(shown != .waitingForInput)
        #expect(rig.attentionCount() == 0, "AC-4: attention must not light for a dead host")
    }

    /// Recovery is the flip side of the negative, and it is what justifies deriving the
    /// state rather than storing it: the model kept the truth the whole time.
    @Test("AC-3: the link coming back restores the observed state")
    func theLinkComingBackRestoresTheObservedState() async throws {
        let rig = try await Rig(host: "flaky.invalid")
        defer { rig.tearDown() }
        try await rig.driveToRunning()

        rig.transport.finish(RemoteEventRelay.sshFailureExit)
        await rig.pollBoardOnce()
        #expect(rig.rendered()?.card.state == .unreachable)
        #expect(rig.shell.cards.first?.state == .running, "the model never lost the truth")

        // Bytes arriving ARE the link being alive again — even these, which the dedup
        // drops as a replay: the evidence is that they arrived, not what they said.
        rig.emit(["PreToolUse"])
        await rig.pollBoardOnce()

        #expect(rig.rendered()?.card.state == .running)
    }

    // MARK: - AC-4: it is visible, and distinct from done and from "not observed"

    /// TC-E2E-020. Asserted on the real mounted view: its class, its own text, its own
    /// colour — never a bitmap of it.
    @Test("AC-4: the dead link is a custom-drawn chip on the card the board mounted")
    func theDeadLinkIsVisibleOnTheMountedCard() async throws {
        let rig = try await Rig(host: "visible.invalid")
        defer { rig.tearDown() }
        try await rig.driveToRunning()
        #expect(Self.linkChip(in: try #require(rig.rendered())) == nil,
                "a healthy card carries no link chip")

        rig.transport.finish(RemoteEventRelay.sshFailureExit)
        await rig.pollBoardOnce()

        let view = try #require(rig.rendered())
        let mounted = try #require(
            Self.identified("link-chip", in: view), "the chip must be in the card's tree")
        #expect(mounted is ChipLabel)
        #expect(!(mounted is NSButton), "a stock control here is the invisible-pill defect")
        let chip = try #require(mounted as? LinkChip)
        #expect(chip.stringValue == "unreachable")
        #expect(chip.textColor == BoardTheme.stateColor(.unreachable))
        #expect(chip.themedBackground != nil, "it paints its own fill, like every chip here")
    }

    /// The two readings it must never be confused with. `done` is a finished task;
    /// "not observed" is a card nothing ever reported on. Neither means "gone".
    @Test("AC-4: unreachable reads differently from done and from not-observed")
    func unreachableIsDistinctFromDoneAndFromNotObserved() throws {
        #expect(BoardTheme.stateColor(.unreachable) != BoardTheme.stateColor(.done))
        #expect(BoardTheme.stateColor(.unreachable) != BoardTheme.stateColor(.unknown))
        #expect(DrillInPanel.statusLabel(.unreachable) == "unreachable")
        #expect(DrillInPanel.statusLabel(.unreachable) != DrillInPanel.statusLabel(.done))
        #expect(DrillInPanel.statusLabel(.unreachable) != DrillInPanel.statusLabel(.unknown))
        #expect(TaskSwitcherOverlay.calmStateWord(.unreachable) == "unreachable")

        // A done card and a never-observed card both stay free of the marker.
        for state in [CardState.done, .unknown] {
            let view = SessionCard(card: Self.card(state: state), hostState: { _ in .installed })
            #expect(Self.linkChip(in: view) == nil, "\(state) must not borrow the dead-link chip")
        }
        // "Not observed" keeps its own sentence (US-005 AC-7), which is not this one.
        let unobserved = SessionCard(
            card: Self.card(state: .unknown), hostState: { _ in .unknown })
        let chip = try #require(Self.hostChip(in: unobserved))
        #expect(chip.stringValue == "not started by Sich")
        #expect(!chip.stringValue.contains("unreachable"))
    }

    // MARK: - Edge: a reachable host with no forwarder is an install message

    /// US-005 AC-7 wins over silence: nothing has reported from that host because
    /// nothing is installed there, and the link is fine. Saying `unreachable` would be
    /// a lie the operator would go debug the network over.
    @Test("edge: a reachable host with no forwarder is an install state, never unreachable")
    func aReachableHostWithNoForwarderIsNotUnreachable() async throws {
        let rig = try await Rig(host: "bare.invalid", installState: .notInstalled)
        defer { rig.tearDown() }

        // The child is up and has said nothing — an absent remote log looks exactly
        // like this, and it is not a dead link.
        #expect(rig.poller.relayHealth(for: rig.host) == .connecting)
        await rig.pollBoardOnce()

        let view = try #require(rig.rendered())
        #expect(view.card.state != .unreachable)
        #expect(Self.linkChip(in: view) == nil)
        let chip = try #require(Self.hostChip(in: view))
        #expect(chip.status.text == "hooks not installed")
        #expect(chip.stringValue == "⚠ no hooks")
    }

    // MARK: - Harness

    /// One board wired to one stand-in host: a real ``BoardShell`` with a real
    /// ``SessionsPoller``, and an in-memory transport standing in for the ssh child.
    @MainActor
    private struct Rig {
        let shell: BoardShell
        let root: NSView
        let poller: SessionsPoller
        let transport: ReconnectTransport
        let spec: RemoteTmuxSpec
        let local: LocalSink
        let card: BoardCard
        var host: String { spec.host }

        init(host: String, installState: RemoteHookInstallState = .installed) async throws {
            spec = RemoteTmuxSpec(host: host, user: "roman")
            local = try LocalSink()
            try local.seed(#"{"hook_event_name":"SessionStart","session_id":"local-only"}"#)
            shell = BoardShell(seeds: [])
            root = shell.buildContentForTesting()
            transport = ReconnectTransport()
            // A huge backstop interval: every poll in these tests is one this file fired,
            // so a pass can never be the 3s timer happening to tick.
            let poller = SessionsPoller(
                eventsFile: local.file, interval: 86_400,
                sink: { [shell] cards in shell.applySessions(cards) })
            poller.start()
            // Attach BEFORE the card exists, so the board's own `attachRemoteHost` (which
            // would use the real ssh transport) is the idempotent no-op, not this.
            poller.attachRemoteHost(spec, transport: transport)
            self.poller = poller
            shell.sessionsPoller = poller
            card = try #require(shell.createRemoteTmuxSession(spec: spec))
            RemoteHookStatus.shared.setState(
                installState, for: try RemoteTmuxCommand.destination(for: spec))
            root.layoutSubtreeIfNeeded()
        }

        func tearDown() {
            poller.stop()
            shell.e2eTeardown()
            local.tearDown()
        }

        /// One board poll cycle, through the FS-watch handler the kernel source uses —
        /// deterministic, no wall-clock sleep, and it ends in `applySessions` → render.
        func pollBoardOnce() async {
            poller.fireWatchForTesting()
            await poller.drainForTesting()
            root.layoutSubtreeIfNeeded()
        }

        /// Relay a turn's worth of hook lines from the far side and wait for the board
        /// to read `expected`. The relay sinks on its own thread and hops back to the
        /// main actor, so this polls; the deadline is generous because a main-actor-bound
        /// suite elsewhere can hold that actor for ~12s under full-suite concurrency.
        /// Hand the relay a turn's worth of far-side hook lines, exactly as the ssh
        /// child would have.
        func emit(_ events: [String]) {
            transport.emit(events.map { LinkHealthTests.hookLine($0, cardID: card.id.uuidString) })
        }

        func drive(events: [String], until expected: CardState) async throws {
            emit(events)
            let box = StateBox()
            for _ in 0..<1_500 where box.value != expected {
                box.value = rendered()?.card.state
                if box.value == expected { break }
                try await Task.sleep(nanoseconds: 20_000_000)
                root.layoutSubtreeIfNeeded()
            }
            #expect(box.value == expected,
                    "the board never reached \(expected) — got \(String(describing: box.value))")
        }

        func driveToRunning() async throws {
            try await drive(events: ["UserPromptSubmit", "PreToolUse"], until: .running)
        }

        /// The card view the BOARD mounted — not one this test built, which is the
        /// difference between "the state exists" and "the state reaches the screen".
        func rendered() -> SessionCard? { LinkHealthTests.sessionCard(for: card.id, in: root) }

        func attentionCount() -> Int { shell.lastAttentionCount }
    }

    /// A main-actor-confined box, so the polling loop above reads a value it owns
    /// rather than reaching across an isolation boundary.
    @MainActor
    private final class StateBox {
        var value: CardState?
    }

    // MARK: - Lookups

    /// The bytes the far-side forwarder ships: Claude's hook payload with the
    /// `sich_card_id` stamp that binds it to the card the board minted — and, as
    /// always, no field naming a machine (the host is stamped at ingestion).
    private static func hookLine(_ event: String, cardID: String) -> String {
        """
        {"session_id":"c0ffee-remote-1","transcript_path":"/home/roman/.claude/x.jsonl",\
        "cwd":"/srv/app","hook_event_name":"\(event)","sich_card_id":"\(cardID)"}
        """
    }

    private static func card(state: CardState) -> BoardCard {
        BoardCard(
            sessionID: "local-abc", title: "some work", projectDir: "/tmp/proj",
            agent: .claude, flow: .b, state: state)
    }

    /// The worst-case detection budget ssh is actually told to use, read back out of
    /// the argv rather than off a constant — a test that restated the numbers would
    /// pass even if the flags never reached the command line.
    private static func keepaliveBudget(in argv: [String]) -> TimeInterval {
        func value(_ key: String) -> TimeInterval {
            argv.compactMap { $0.hasPrefix("\(key)=") ? TimeInterval($0.dropFirst(key.count + 1)) : nil }
                .first ?? 0
        }
        return value("ServerAliveInterval") * value("ServerAliveCountMax")
    }

    private static func sessionCard(for id: UUID, in view: NSView) -> SessionCard? {
        if let card = view as? SessionCard, card.card.id == id { return card }
        for sub in view.subviews {
            if let found = sessionCard(for: id, in: sub) { return found }
        }
        return nil
    }

    /// Type-erased lookup, so the render-path assertion is a real runtime check on the
    /// mounted view rather than a cast the compiler folds away.
    private static func identified(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == name { return view }
        for sub in view.subviews {
            if let found = identified(name, in: sub) { return found }
        }
        return nil
    }

    private static func linkChip(in view: NSView) -> LinkChip? {
        if let chip = view as? LinkChip { return chip }
        for sub in view.subviews {
            if let found = linkChip(in: sub) { return found }
        }
        return nil
    }

    private static func hostChip(in view: NSView) -> HostChip? {
        if let chip = view as? HostChip { return chip }
        for sub in view.subviews {
            if let found = hostChip(in: sub) { return found }
        }
        return nil
    }
}
