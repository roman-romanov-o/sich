import Foundation
import SichCore

/// The bridge from the observe-only event-file sink (DD-002) to the live board.
///
/// A hook-observed session is a human-driven interactive Claude Code run (flow B)
/// we *watch* but never spawned — so it carries no PTY of ours and is not drillable
/// (BoardShell's drill guard no-ops on a card with no PTY). This is the
/// watcher-not-spawner constraint reaching the board: real sessions appear because
/// their hooks APPEND a line to `~/.sich/events.jsonl`, which the app tails —
/// no server, no port, no reply.

// MARK: - Reconciled entry → board card

/// Decode a reconciled `HookSessionStore.Entry` into the board's card snapshot.
enum SessionsFeed {
    static func cards(from entries: [HookSessionStore.Entry]) -> [BoardCard] {
        entries.map(card(from:))
    }

    static func card(from entry: HookSessionStore.Entry) -> BoardCard {
        BoardCard(
            sessionID: entry.sessionID,
            projectDir: entry.projectDir ?? entry.sessionID,  // label by repo, fall back to id
            agent: entry.agent,
            flow: .b,        // hook-observed == human-launched interactive (flow B)
            state: CardState(rawValue: entry.state.rawValue) ?? .unknown,
            updatedAt: entry.updatedAt,  // freshness key: newest observation wins on a dir join
            boundCardID: entry.cardID,   // identity binding to the owned card, if spawned by us
            host: entry.host             // provenance: which machine observed it (US-004 AC-3)
        )
    }

    /// Normalize each raw event-file line into a signal, ROUTING a jsonl-tagged
    /// transcript record (`"source":"jsonl"`) to the JSONL fallback normalizer and
    /// every other line to the hook normalizer. This is what lets a DROPPED `Stop`
    /// hook still converge to `done`: the transcript's `turn_completed` record (lower
    /// precedence than a hook, so it never overrides a live one — see
    /// `HookSessionStore` source rank) reconstructs the exit the missing hook would
    /// have carried (US-002 / TC-INT-010). The reconciler's coalescing + no-flicker
    /// write dedups a Stop that arrives on BOTH streams by sessionID+timestamp, so it
    /// lands once.
    // periphery:ignore - test-only entry (scan runs with exclude_tests)
    static func normalize(_ lines: [Data], arrival: Date) -> [SignalEvent] {
        parse(lines, arrival: arrival).events
    }

    /// One drained batch, classified: turn diffs for the drill-in review, signal
    /// events for the reconciler. `Sendable` because the parse runs OFF the main
    /// actor and only this result crosses back.
    struct ParsedEventBatch: Sendable {
        let diffs: [TurnDiff]
        let events: [SignalEvent]
    }

    /// Classify every drained line from ONE `JSONSerialization` pass. This used to
    /// be normalize-to-exclude — each line was fully parsed 2–4 times (a multi-MB
    /// `turn_diff` line twice, base64 decode included) — which, on the main actor,
    /// was the typing-glitch stall. A line routes to exactly one normalizer:
    /// `sich_event_type == "turn_diff"` → diff; `"source":"jsonl"` (the transcript
    /// fallback stream's self-identifying tag) → JSONL; anything else → hook. A
    /// turn-diff line with an undecodable payload falls through to the hook
    /// normalizer as an unknown-kind signal, same as before.
    static func parse(_ lines: [Data], arrival: Date) -> ParsedEventBatch {
        collect(lines.count, arrival: arrival) { index in
            (try? JSONSerialization.jsonObject(with: lines[index])) as? [String: Any]
        }
    }

    /// The REMOTE intake (US-003 AC-2): the same classification, over lines whose
    /// payload is stamped with `sich_host` first. The stamp happens here, at
    /// ingestion, BEFORE any normalizer sees the payload — the host is knowledge the
    /// channel has and the bytes do not.
    static func parse(_ lines: [RemoteEventLine], arrival: Date) -> ParsedEventBatch {
        collect(lines.count, arrival: arrival) { index in lines[index].stampedPayload() }
    }

    /// Shared body of the two intakes: stamp arrival order, then route.
    private static func collect(
        _ count: Int, arrival: Date, payload: (Int) -> [String: Any]?
    ) -> ParsedEventBatch {
        var diffs: [TurnDiff] = []
        var events: [SignalEvent] = []
        for index in 0..<count {
            // File order IS arrival order. Hook payloads carry no timestamp, so a
            // whole poll batch would share one `arrival` stamp, coalesce into one
            // burst, and let the reconciler's tie-break pick an ARBITRARY event of
            // the batch (Swift `max(by:)` keeps the first on all-equal — e.g. a
            // Notification hiding behind a SubagentStop). A strictly increasing
            // sub-second offset per line keeps the last-written event dominant.
            let stamped = arrival.addingTimeInterval(Double(index) / 1_000)
            guard let payload = payload(index) else { continue }
            // non-JSON line: skipped, not fatal (US-003 edge 4)
            route(payload, arrival: stamped, diffs: &diffs, events: &events)
        }
        return ParsedEventBatch(diffs: diffs, events: events)
    }

    private static func route(
        _ payload: [String: Any], arrival: Date,
        diffs: inout [TurnDiff], events: inout [SignalEvent]
    ) {
        if let diff = TurnDiffNormalizer.normalize(payload: payload, arrival: arrival) {
            diffs.append(diff)
        } else if payload["source"] as? String == "jsonl" {
            events.append(JSONLNormalizer.normalize(payload: payload, arrival: arrival))
        } else {
            events.append(HookNormalizer.normalize(payload: payload, arrival: arrival))
        }
    }
}

// MARK: - Event-driven delivery (tail → normalize → ingest → sweep)

/// Drains the event file, reconciles each line into a local `HookSessionStore`,
/// sweeps stale sessions on the same read (sweep-on-poll, mirroring the Python
/// sweep-on-read — no background timer), and pushes fresh board cards to a main-actor
/// sink. A read hiccup is a no-op: the board keeps its last snapshot rather than
/// blanking on a blip.
///
/// Delivery is event-driven (DD-002 / US-001): a `FileWatcher` FS-object watch is the
/// PRIMARY trigger (sub-250ms after a hook lands), and the demoted low-frequency
/// `Timer` is a BACKSTOP that covers a missed FS event or a rotation re-arm gap. Both
/// call the same incremental `poll()`.
///
/// The drain (file read + JSON parse) runs OFF the main actor: a dirty-repo `Stop`
/// hook appends a multi-MB `turn_diff` line, and parsing it on the main actor stalled
/// typing in the drilled-in terminal for hundreds of ms; a rotation or a cold start
/// re-reads a whole file the same way (the launch stutter). Only the cheap tail —
/// store ingest + the two sinks — hops back to the main actor. The `inFlight` guard
/// keeps exactly one drain alive (the tail's offset file is read-modify-write, so
/// drains must never overlap), and a trigger that lands mid-drain coalesces into one
/// follow-up poll instead of being dropped.
///
/// Watcher-not-spawner: the file is read-only to the app; this loop spawns nothing,
/// binds no port, and never replies.
@MainActor
public final class SessionsPoller {
    private let eventsFile: URL
    private let tail: HookEventTail
    private let store: HookSessionStore
    private let backstopInterval: TimeInterval
    private let sink: ([BoardCard]) -> Void
    private let diffSink: ([TurnDiff]) -> Void
    /// Turns keyed by session IDENTITY — `host` included, because two machines
    /// running one repo emit the same session id AND the same iteration, and an
    /// id-only key made the second host's turn overwrite the first's (US-004 AC-3).
    private var diffsBySession: [DiffKey: [TurnDiff]] = [:]
    /// Every turn diff already folded into the review pane, by content identity — the
    /// reconnect replay guard (US-008 AC-2). Digests only, 32 bytes a turn.
    private var deliveredDiffs: Set<TurnDiffKey> = []

    private struct DiffKey: Hashable {
        let host: String?
        let sessionID: String

        // Spelled out rather than synthesized: both fields are load-bearing identity,
        // and the dead-code scanner cannot see through a compiler-generated conformance.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.host == rhs.host && lhs.sessionID == rhs.sessionID
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(host)
            hasher.combine(sessionID)
        }
    }
    private var timer: Timer?
    private var watcher: FileWatcher?
    private var relays: [String: RemoteEventRelay] = [:]   // one per followed host
    private var inFlight = false      // exactly one drain at a time (offset-file safety)
    private var pendingPoll = false   // a trigger landed mid-drain → re-poll after apply
    private var currentDrain: Task<Void, Never>?

    /// `stallThreshold` rides through to the store's rule-2.1 stall guard (default
    /// 10 min); injectable so an E2E test can provoke a real stall in seconds.
    /// The backstop poll cadence. Also the bound on how long a change the board
    /// derives from poller state — a host's link health (US-007 AC-1) — can take to
    /// reach the screen, since every backstop tick pushes cards to the sink whether
    /// or not any line arrived.
    public static let defaultInterval: TimeInterval = 3

    public init(
        eventsFile: URL = SessionsPoller.defaultEventsFile,
        interval: TimeInterval = SessionsPoller.defaultInterval,
        stallThreshold: TimeInterval = 600,
        diffSink: @escaping ([TurnDiff]) -> Void = { _ in },
        sink: @escaping ([BoardCard]) -> Void
    ) {
        self.eventsFile = eventsFile
        self.tail = HookEventTail(file: eventsFile)
        self.store = HookSessionStore(stallThreshold: stallThreshold)
        self.backstopInterval = interval
        self.diffSink = diffSink
        self.sink = sink
    }

    /// `~/.sich/events.jsonl`, overridable via `SICH_EVENTS_FILE` (the same
    /// override the forwarder honors).
    public static var defaultEventsFile: URL {
        if let override = ProcessInfo.processInfo.environment["SICH_EVENTS_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sich/events.jsonl")
    }

    public func start() {
        poll()          // cold-start drain from the persisted offset (off-main, async)
        armWatch()      // primary trigger: event-driven, sub-250ms
        armBackstop()   // safety net at the low-frequency interval
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        relays.values.forEach { $0.stop() }
        relays.removeAll()
    }

    private func armWatch() {
        if watcher == nil {
            watcher = FileWatcher(path: eventsFile.path) { [weak self] in self?.onFileEvent() }
        }
        watcher?.start()
    }

    /// The demoted 3s `Timer`: a BACKSTOP, not the primary trigger. It also re-arms the
    /// FS-watch if it dropped (e.g. the event file did not exist at launch).
    private func armBackstop() {
        timer = Timer.scheduledTimer(withTimeInterval: backstopInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
                self?.ensureWatchArmed()
            }
        }
    }

    private func ensureWatchArmed() {
        if watcher?.isArmed != true { armWatch() }
    }

    /// The FS-watch routes here — kept distinct from `poll()` so a test can assert the
    /// read fired *because the watch fired*, not because the backstop timer ticked.
    private func onFileEvent() { poll() }

    /// Kick off one background drain. Never blocks the main actor: the read+parse
    /// happens in a detached task and `apply` finishes on the main actor.
    private func poll() {
        guard !inFlight else {
            pendingPoll = true   // coalesce: one follow-up drain covers every trigger
            return
        }
        inFlight = true
        let tail = self.tail
        currentDrain = Task.detached(priority: .userInitiated) { [weak self] in
            let now = Date()
            let batch = SessionsFeed.parse(tail.poll(), arrival: now)
            await self?.apply(batch, now: now)   // hops back to the main actor
        }
    }

    /// The main-actor tail of a LOCAL drain: release the drain guard, fold the batch,
    /// then honour a trigger that landed while the drain was running.
    private func apply(_ batch: SessionsFeed.ParsedEventBatch, now: Date) {
        inFlight = false
        applyBatch(batch, now: now)
        if pendingPoll {
            pendingPoll = false
            poll()
        }
    }

    /// Fold one batch — from either intake — into the store and out to the sinks.
    /// Cheap, no parsing.
    private func applyBatch(_ batch: SessionsFeed.ParsedEventBatch, now: Date) {
        var changed = false
        for diff in batch.diffs where deliveredDiffs.insert(TurnDiffKey(diff)).inserted {
            changed = true
            let key = DiffKey(host: diff.host, sessionID: diff.sessionID)
            var turns = diffsBySession[key, default: []]
            // Insert in iteration order WITHOUT sorting: two Stops inside one turn are
            // two distinct diffs under one iteration, and a sort is not stable — the
            // pair would reorder arbitrarily between polls. Arrival order breaks the tie.
            let index = turns.firstIndex { $0.iteration > diff.iteration } ?? turns.count
            turns.insert(diff, at: index)
            diffsBySession[key] = turns
        }
        store.ingest(batch.events)
        store.sweepStale(now: now)
        // Redeliver the diff set only when this batch actually changed it — the full
        // flatMap used to run on EVERY poll (any hook line), re-rendering the
        // drill-in's diff sidebar for nothing. A replayed diff changes nothing.
        if changed {
            diffSink(diffsBySession.values.flatMap { $0 })
        }
        sink(SessionsFeed.cards(from: store.entries))
    }

    // MARK: - Remote intake (US-003)

    /// Follow one remote host's event log and fold its lines into the SAME store the
    /// local sink feeds (DD-001). In memory the whole way: a relayed line is never
    /// written into the local `~/.sich/events.jsonl` and never touches the local
    /// tail's offset file — there is one writer of that file, the local forwarder.
    ///
    /// Idempotent per host, so re-opening a card on a host already followed does not
    /// start a second ssh. Inert unless the real executable enabled spawning.
    public func attachRemoteHost(
        _ spec: RemoteTmuxSpec, transport: RemoteLineTransport = SSHLineTransport()
    ) {
        guard let host = try? RemoteTmuxCommand.hostToken(for: spec),
              relays[host] == nil,
              let relay = try? RemoteEventRelay(spec: spec, transport: transport, sink: { [weak self] lines in
                  self?.receiveRemote(lines)
              })
        else { return }
        relays[host] = relay
        relay.start()
    }

    /// The relay reads on its own thread; parse there (a `turn_diff` line runs to
    /// megabytes and would stall typing on the main actor) and hop back with the
    /// finished batch, exactly like the local drain does.
    private nonisolated func receiveRemote(_ lines: [RemoteEventLine]) {
        let now = Date()
        let batch = SessionsFeed.parse(lines, arrival: now)
        Task { @MainActor [weak self] in self?.applyBatch(batch, now: now) }
    }

    /// Health of one followed host — `unreachable` only when ssh itself failed. `nil`
    /// for a host no relay follows, which is not a verdict about the host at all.
    /// The board reads this every render to overlay `CardState.unreachable` (US-007).
    func relayHealth(for host: String) -> RemoteRelayHealth? { relays[host]?.health }

    /// Test seam (TC-INT-002, DD-002 anti-flake): deliver a file-write through the
    /// SAME watcher handler the kernel source uses, deterministically — no real FS
    /// race, no wall-clock latency. With the backstop interval set huge, a read here
    /// can only have come from the FS-watch path.
    func fireWatchForTesting() { watcher?.fireForTesting() }

    /// Await the completion of every in-flight AND chained-pending drain. The drain
    /// went async (off-main parse), so a test that fires a trigger must await this
    /// before asserting on the sink — deterministically, no wall-clock sleeps. The
    /// loop re-checks because a trigger that landed mid-drain chains a follow-up.
    // periphery:ignore - test-only entry (scan runs with exclude_tests)
    func drainForTesting() async {
        while inFlight, let task = currentDrain {
            await task.value
        }
    }
}
