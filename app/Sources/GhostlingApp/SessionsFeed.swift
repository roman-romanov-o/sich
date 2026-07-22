import Foundation
import GhostlingCore

/// The bridge from the observe-only event-file sink (DD-002) to the live board.
///
/// A hook-observed session is a human-driven interactive Claude Code run (flow B)
/// we *watch* but never spawned — so it carries no PTY of ours and is not drillable
/// (BoardShell's drill guard no-ops on a card with no PTY). This is the
/// watcher-not-spawner constraint reaching the board: real sessions appear because
/// their hooks APPEND a line to `~/.ghostling/events.jsonl`, which the app tails —
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
        lines.enumerated().compactMap { index, line in
            // File order IS arrival order. Hook payloads carry no timestamp, so a
            // whole poll batch would share one `arrival` stamp, coalesce into one
            // burst, and let the reconciler's tie-break pick an ARBITRARY event of
            // the batch (Swift `max(by:)` keeps the first on all-equal — e.g. a
            // Notification hiding behind a SubagentStop). A strictly increasing
            // sub-second offset per line keeps the last-written event dominant.
            let stamped = arrival.addingTimeInterval(Double(index) / 1_000)
            guard TurnDiffNormalizer.normalize(line, arrival: stamped) == nil else { return nil }
            return isJSONL(line)
                ? JSONLNormalizer.normalize(line, arrival: stamped)
                : HookNormalizer.normalize(line, arrival: stamped)
        }
    }

    /// A transcript record on the JSONL fallback stream is self-identifying by a
    /// `"source":"jsonl"` tag (the same convention the store-level reconciler test
    /// uses), so the tail can carry both hook lines and transcript records in one
    /// append-only file without a second watcher.
    private static func isJSONL(_ line: Data) -> Bool {
        let object = try? JSONSerialization.jsonObject(with: line)
        return (object as? [String: Any])?["source"] as? String == "jsonl"
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
/// call the same incremental `poll()` — `readNew()` is the only offset mutator, on the
/// main actor — so they never tear.
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

    /// `~/.ghostling/events.jsonl`, overridable via `GHOSTLING_EVENTS_FILE` (the same
    /// override the forwarder honors).
    public static var defaultEventsFile: URL {
        if let override = ProcessInfo.processInfo.environment["GHOSTLING_EVENTS_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghostling/events.jsonl")
    }

    public func start() {
        poll()          // cold-start drain from the persisted offset
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

    private func poll() {
        let now = Date()
        let lines = tail.poll()
        for diff in lines.compactMap({ TurnDiffNormalizer.normalize($0, arrival: now) }) {
            var turns = diffsBySession[diff.sessionID, default: []]
            if let index = turns.firstIndex(where: { $0.iteration == diff.iteration }) {
                turns[index] = diff
            } else {
                turns.append(diff)
                turns.sort { $0.iteration < $1.iteration }
            }
            diffsBySession[diff.sessionID] = turns
        }
        let events = SessionsFeed.normalize(lines, arrival: now)
        store.ingest(events)
        store.sweepStale(now: now)
        diffSink(diffsBySession.values.flatMap { $0 })
        sink(SessionsFeed.cards(from: store.entries))
    }

    /// Test seam (TC-INT-002, DD-002 anti-flake): deliver a file-write through the
    /// SAME watcher handler the kernel source uses, deterministically — no real FS
    /// race, no wall-clock latency. With the backstop interval set huge, a read here
    /// can only have come from the FS-watch path.
    func fireWatchForTesting() { watcher?.fireForTesting() }
}
