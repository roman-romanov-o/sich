import Foundation
import Testing

@testable import SichApp
@testable import SichCore

/// US-008 — a reconnect must not duplicate history.
///
/// The relay's raw-line window (ts-unit-02) is the first line of defence and catches
/// a byte-identical replay. These cover what a replay must never do to a card's
/// state, driven through the production path (fixture host → relay → store).
@Suite("Reconnect does not duplicate history (US-008)")
struct RemoteReconnectTests {

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
