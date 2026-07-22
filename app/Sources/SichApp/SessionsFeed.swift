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
            boundCardID: entry.cardID    // identity binding to the owned card, if spawned by us
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
        var diffs: [TurnDiff] = []
        var events: [SignalEvent] = []
        for (index, line) in lines.enumerated() {
            // File order IS arrival order. Hook payloads carry no timestamp, so a
            // whole poll batch would share one `arrival` stamp, coalesce into one
            // burst, and let the reconciler's tie-break pick an ARBITRARY event of
            // the batch (Swift `max(by:)` keeps the first on all-equal — e.g. a
            // Notification hiding behind a SubagentStop). A strictly increasing
            // sub-second offset per line keeps the last-written event dominant.
            let stamped = arrival.addingTimeInterval(Double(index) / 1_000)
            guard let payload = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { continue }   // non-JSON line: skipped, not fatal (US-003 edge 4)
            if let diff = TurnDiffNormalizer.normalize(payload: payload, arrival: stamped) {
                diffs.append(diff)
            } else if payload["source"] as? String == "jsonl" {
                events.append(JSONLNormalizer.normalize(payload: payload, arrival: stamped))
            } else {
                events.append(HookNormalizer.normalize(payload: payload, arrival: stamped))
            }
        }
        return ParsedEventBatch(diffs: diffs, events: events)
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
    private var diffsBySession: [String: [TurnDiff]] = [:]
    private var timer: Timer?
    private var watcher: FileWatcher?
    private var inFlight = false      // exactly one drain at a time (offset-file safety)
    private var pendingPoll = false   // a trigger landed mid-drain → re-poll after apply
    private var currentDrain: Task<Void, Never>?

    /// `stallThreshold` rides through to the store's rule-2.1 stall guard (default
    /// 10 min); injectable so an E2E test can provoke a real stall in seconds.
    public init(
        eventsFile: URL = SessionsPoller.defaultEventsFile,
        interval: TimeInterval = 3,
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

    /// The main-actor tail of a drain: ingest + sweep + sinks — cheap, no parsing.
    private func apply(_ batch: SessionsFeed.ParsedEventBatch, now: Date) {
        inFlight = false
        for diff in batch.diffs {
            var turns = diffsBySession[diff.sessionID, default: []]
            if let index = turns.firstIndex(where: { $0.iteration == diff.iteration }) {
                turns[index] = diff
            } else {
                turns.append(diff)
                turns.sort { $0.iteration < $1.iteration }
            }
            diffsBySession[diff.sessionID] = turns
        }
        store.ingest(batch.events)
        store.sweepStale(now: now)
        // Redeliver the diff set only when this batch actually changed it — the full
        // flatMap used to run on EVERY poll (any hook line), re-rendering the
        // drill-in's diff sidebar for nothing.
        if !batch.diffs.isEmpty {
            diffSink(diffsBySession.values.flatMap { $0 })
        }
        sink(SessionsFeed.cards(from: store.entries))
        if pendingPoll {
            pendingPoll = false
            poll()
        }
    }

    /// Test seam (TC-INT-002, DD-002 anti-flake): deliver a file-write through the
    /// SAME watcher handler the kernel source uses, deterministically — no real FS
    /// race, no wall-clock latency. With the backstop interval set huge, a read here
    /// can only have come from the FS-watch path.
    func fireWatchForTesting() { watcher?.fireForTesting() }

    /// Await the completion of every in-flight AND chained-pending drain. The drain
    /// went async (off-main parse), so a test that fires a trigger must await this
    /// before asserting on the sink — deterministically, no wall-clock sleeps. The
    /// loop re-checks because a trigger that landed mid-drain chains a follow-up.
    func drainForTesting() async {
        while inFlight, let task = currentDrain {
            await task.value
        }
    }
}
