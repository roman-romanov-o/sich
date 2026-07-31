import Foundation
import Testing

@testable import SichApp
@testable import SichCore

/// US-008 — a reconnect must not duplicate history.
///
/// The relay's raw-line window (ts-unit-02) is the first line of defence and catches
/// a byte-identical replay. These are the cases it CANNOT catch, driven through the
/// production path (fixture host → relay → poller → the drill-in's diff sink):
///  * two Stops inside one turn ship two different diffs under ONE iteration number,
///    and both must survive;
///  * the same diff re-shipped under a different whole-second `timestamp` is different
///    bytes, so it reaches the poller — and must land as one turn, not two.
@Suite("Reconnect does not duplicate history (US-008)")
struct RemoteReconnectTests {

    @Test("AC-2: two Stops in one iteration are two turns in drill-in, not one overwrite")
    @MainActor func twoStopsInOneIterationBothReachDrillIn() async throws {
        let far = try RelayHost()
        defer { far.tearDown() }
        let (poller, diffs, transport, local) = try attachedPoller(to: far)
        defer { poller.stop(); local.tearDown() }

        // `iteration` bumps on UserPromptSubmit only; the Stop that ships a diff merely
        // reads it. One prompt, two Stops, two different diffs, one iteration number.
        transport.emit([
            far.diff(iteration: 1, body: "--- a/x\n+++ b/x\n@@\n+one\n", stamp: "2026-07-30T10:00:00Z"),
            far.diff(iteration: 1, body: "--- a/x\n+++ b/x\n@@\n+one\n+two\n", stamp: "2026-07-30T10:00:05Z"),
        ])

        // The relay hands the batch back through a main-actor hop, and a long
        // main-actor-bound suite elsewhere can hold that actor for ~10s — hence the
        // generous deadline. It resolves in milliseconds when the actor is free.
        #expect(await waitUntil(timeout: 30) { diffs.all.count == 2 },
                "the second Stop's diff must not overwrite the first — got \(diffs.all.count)")
        #expect(Set(diffs.all.map(\.iteration)) == [1])
        #expect(diffs.all.map(\.unifiedDiff).contains { $0.contains("+two") })
    }

    @Test("AC-2: the same diff re-shipped under a later timestamp is one turn")
    @MainActor func aReShippedDiffIsNotADuplicateTurn() async throws {
        let far = try RelayHost()
        defer { far.tearDown() }
        let (poller, diffs, transport, local) = try attachedPoller(to: far)
        defer { poller.stop(); local.tearDown() }

        let body = "--- a/x\n+++ b/x\n@@\n+same\n"
        // Nothing was edited between the two Stops, so `git diff` against the uncleared
        // checkpoint yields identical bytes — under a different second stamp.
        transport.emit([far.diff(iteration: 2, body: body, stamp: "2026-07-30T10:00:00Z")])
        // Same generous deadline as above: the delivery hop queues behind whatever else
        // holds the main actor, so a short wait measures suite load, not this behaviour.
        #expect(await waitUntil(timeout: 30) { diffs.all.count == 1 })

        // The lines differ, so the relay's raw-byte window admits the replay: only the
        // (host, session, iteration, sha256(diff)) key can collapse it.
        transport.emit([
            far.diff(iteration: 2, body: body, stamp: "2026-07-30T10:00:09Z"),
            far.diff(iteration: 3, body: "--- a/x\n+++ b/x\n@@\n+later\n"),
        ])
        #expect(await waitUntil(timeout: 30) { diffs.all.count == 2 },
                "one re-shipped turn plus one new turn — got \(diffs.all.count)")
        #expect(diffs.all.map(\.iteration).sorted() == [2, 3])
    }

    // MARK: - US-008 AC-1: a replay never moves the card backwards

    /// TC-E2E-006, over the composed production pieces: relay → `SessionsFeed.parse`
    /// → the store. The link drops after the Stop and the reconnect re-runs
    /// `tail -n 200`, so the whole turn comes back — and the state PATH must equal the
    /// one a link that never dropped produces.
    @Test("TC-E2E-006 / AC-1: the replayed run's state sequence equals the unbroken run's")
    func aReplayLeavesTheStateSequenceUnchanged() throws {
        let turn = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"]

        let lines = turn.map(hookLine)
        let unbroken = try statePath { transport in transport.emit(lines) }
        let reconnected = try statePath { transport in
            transport.emit(lines)
            transport.finish(RemoteEventRelay.sshFailureExit)  // the link died
            transport.emit(lines)                              // `tail -n 200` replays it
        }

        #expect(unbroken == [.running, .waitingForInput])
        #expect(reconnected == unbroken, "the replay must not extend the path — got \(reconnected)")
    }

    @Test("AC-1: a stale tool call does not extinguish the attention signal")
    func aStaleToolCallDoesNotClearAttention() {
        let store = HookSessionStore()
        store.ingest(events(["UserPromptSubmit", "Stop"]))
        #expect(store.entry(for: "far-session", host: "far.invalid")?.state == .waitingForInput)

        store.ingest(events(["PostToolUse", "SessionStart"], from: 100))
        #expect(store.entry(for: "far-session", host: "far.invalid")?.state == .waitingForInput,
                "a card asking for you cannot be put back to WORKING by a replayed hook")
    }

    /// Secondary case: `Stop` is the turn boundary, so a replayed one must leave a card
    /// exactly where the live one did — never at rest, which would drop it out of the
    /// NEEDS YOU column.
    @Test("AC-1: a replayed Stop leaves the card in NEEDS YOU, not at rest")
    func aReplayedStopDoesNotSettleTheCard() {
        let store = HookSessionStore()
        store.ingest(events(["UserPromptSubmit", "PostToolUse", "Stop"]))
        store.ingest(events(["Stop"], from: 200))

        let key = (id: "far-session", host: "far.invalid")
        #expect(store.entry(for: key.id, host: key.host)?.state == .waitingForInput)
        #expect(store.transitions(for: key.id, host: key.host) == [.running, .waitingForInput])
    }

    // MARK: - Fixtures

    /// Drive one relay through `script`, folding everything it hands out into a store
    /// exactly as the poller does, and return the state path that produced.
    private func statePath(_ script: (ReconnectTransport) -> Void) throws -> [CardState] {
        let clock = ArrivalClock()
        let delivered = EventBox()
        let transport = ReconnectTransport()
        let relay = try RemoteEventRelay(
            spec: RemoteTmuxSpec(host: "far.invalid"), transport: transport, reconnectDelay: 0,
            sink: { lines in delivered.add(SessionsFeed.parse(lines, arrival: clock.next()).events) })
        relay.start()
        defer { relay.stop() }
        script(transport)

        let store = HookSessionStore(coalesceWindow: 0)
        store.ingest(delivered.all)
        return store.transitions(for: "far-session", host: "far.invalid")
    }

    /// The bytes the far-side forwarder appends — no field naming a machine.
    private func hookLine(_ hook: String) -> String {
        #"{"session_id":"far-session","cwd":"/srv/app","hook_event_name":"\#(hook)"}"#
    }

    /// Remote hook events, one per second so the burst coalescer keeps them distinct.
    private func events(_ hooks: [String], from offset: TimeInterval = 0) -> [SignalEvent] {
        hooks.enumerated().map { index, hook in
            HookNormalizer.normalize(
                payload: [
                    "hook_event_name": hook, "session_id": "far-session", "cwd": "/srv/app",
                    RemoteEventLine.hostKey: "far.invalid",
                ],
                arrival: Date(timeIntervalSince1970: 1_000 + offset + Double(index) * 5))
        }
    }

    /// A poller fed by a local sink it will not see anything on, with `far` attached
    /// over an IN-MEMORY transport — the same wiring the board uses, minus the ssh
    /// child, so delivery is deterministic instead of racing a real `tail` under load.
    @MainActor private func attachedPoller(
        to far: RelayHost
    ) throws -> (SessionsPoller, DiffBox, ReconnectTransport, LocalSink) {
        let local = try LocalSink()
        try local.seed(#"{"hook_event_name":"SessionStart","session_id":"local-only"}"#)
        let diffs = DiffBox()
        let poller = SessionsPoller(
            eventsFile: local.file, interval: 86_400,
            diffSink: { diffs.set($0) }, sink: { _ in })
        poller.start()
        let transport = ReconnectTransport()
        poller.attachRemoteHost(far.spec, transport: transport)
        return (poller, diffs, transport, local)
    }
}

/// A transport the test drives directly — no ssh, no child process, no host dialled.
/// The relay keeps its handlers across a child exit, so a `finish` + `emit` pair IS the
/// reconnect replay: the same bytes, a second time.
final class ReconnectTransport: RemoteLineTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var onLines: (@Sendable ([Data]) -> Void)?
    private var onExit: (@Sendable (Int32) -> Void)?

    final class Stream: RemoteLineStream, @unchecked Sendable {
        func cancel() {}
    }

    func start(
        argv: [String],
        onLines: @escaping @Sendable ([Data]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> RemoteLineStream? {
        lock.lock()
        self.onLines = onLines
        self.onExit = onExit
        lock.unlock()
        return Stream()
    }

    func emit(_ lines: [String]) {
        lock.lock()
        let handler = onLines
        lock.unlock()
        handler?(lines.map { Data($0.utf8) })
    }

    func finish(_ code: Int32) {
        lock.lock()
        let handler = onExit
        lock.unlock()
        handler?(code)
    }
}

/// Everything the relay handed out, in delivery order — the relay sinks on its own
/// thread, so this crosses one.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SignalEvent] = []

    func add(_ batch: [SignalEvent]) {
        lock.lock()
        events += batch
        lock.unlock()
    }

    var all: [SignalEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// Arrival time advances one batch at a time: the replayed batch arrives LATER than the
/// bytes it repeats, which is exactly why the dedup cannot key on a normalized value.
final class ArrivalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_000

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        seconds += 60
        return Date(timeIntervalSince1970: seconds)
    }
}
