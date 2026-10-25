import Foundation
import SichCore
import Testing

@testable import SichApp

/// The reconciled-entry → board-card seam between the observe-only event-file sink
/// (DD-002) and the board. After the HTTP cutover, sessions arrive as reconciled
/// `HookSessionStore.Entry` values (not a `/sessions` JSON body); these drive the
/// REAL mapping (`SessionsFeed.cards(from:)`) so an entry/board drift is caught
/// before it reaches an NSView. Each hook-observed session is a human-launched
/// Claude Code run we only watch, labelled by repo (falling back to id).
struct SessionsFeedTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func entry(
        _ id: String, _ state: CardState, dir: String?, agent: CardAgent = .claude
    ) -> HookSessionStore.Entry {
        HookSessionStore.Entry(
            sessionID: id, agent: agent, state: state, updatedAt: now, projectDir: dir)
    }

    @Test func mapsEachEntryToAWatchedFlowBCard() {
        let cards = SessionsFeed.cards(from: [entry("sess-normal", .running, dir: "/repo")])
        #expect(cards.count == 1)

        let normal = cards[0]
        #expect(normal.sessionID == "sess-normal")
        #expect(normal.projectDir == "/repo")
        #expect(normal.state == .running)
        #expect(normal.agent == .claude)
    }

    @Test func preservesCodexAgentIdentity() {
        let cards = SessionsFeed.cards(from: [
            entry("codex-session", .waitingForInput, dir: "/repo", agent: .codex)
        ])
        #expect(cards[0].agent == .codex)
        #expect(cards[0].state == .waitingForInput)
    }

    @Test func absentProjectDirFallsBackToTheSessionID() {
        let cards = SessionsFeed.cards(from: [entry("sess-bare", .waitingForInput, dir: nil)])
        #expect(cards[0].projectDir == "sess-bare")  // labelled by id when cwd unknown
        #expect(cards[0].state == .waitingForInput)
    }

    @Test func unknownStatePropagatesAsUnknownNotAGuess() {
        let cards = SessionsFeed.cards(from: [entry("s", .unknown, dir: "/x")])
        #expect(cards[0].state == .unknown)
    }

    // MARK: - TC-INT-002: FS-watch fires the read (event-driven, no backstop)

    private func makeEventsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-feed-\(UUID().uuidString).jsonl")
    }

    private func sessionStart(_ id: String) -> String {
        #"{"hook_event_name":"SessionStart","session_id":"\#(id)"}"#
    }

    private func appendLine(_ line: String, to file: URL) throws {
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: file)
        }
    }

    /// A hook appended AFTER `start()` reaches the board because the FS-watch fired —
    /// the backstop `Timer` is set so large it cannot run during the test, so the read
    /// can only have come from the watch path (DD-002). Asserted deterministically via
    /// the watcher's fire seam, never wall-clock latency (anti-flake — mirrors the
    /// GridTextTests fromPTY PTY-EOF precedent).
    @Test @MainActor func fsWrite_triggersReadWithoutBackstop() async throws {
        let file = makeEventsFile()
        let offset = file.appendingPathExtension("offset")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: offset)
        }
        try appendLine(sessionStart("A"), to: file)

        var snapshot: [BoardCard] = []
        // Backstop deliberately huge → the ONLY trigger that can read is the FS-watch.
        let poller = SessionsPoller(eventsFile: file, interval: 86_400) { snapshot = $0 }
        poller.start()   // cold-start drain sees A
        defer { poller.stop() }
        await poller.drainForTesting()   // the drain parses off-main; await its apply
        #expect(snapshot.contains { $0.sessionID == "A" })
        #expect(!snapshot.contains { $0.sessionID == "B" })

        // A new hook lands after start; with the backstop disabled it can reach the
        // board only via the FS-watch trigger.
        try appendLine(sessionStart("B"), to: file)
        poller.fireWatchForTesting()   // == "the FS-object source fired on .write"
        await poller.drainForTesting()

        #expect(snapshot.contains { $0.sessionID == "B" },
                "the read must have fired because the FS-watch fired (backstop disabled)")
    }

    // MARK: - Batch arrival stamping: file order decides a coalesced burst

    /// Hook payloads carry no timestamp, so a whole poll batch used to share one
    /// arrival stamp — the burst's tie-break then kept the FIRST event (`max(by:)`
    /// on all-equal), letting a SubagentStop hide the Notification written after it.
    /// `normalize` must stamp lines strictly increasing in file order so the
    /// LAST-written event of a same-rank burst is dominant.
    @Test func batchStampsPreserveFileOrderSoLastEventWins() {
        let lines = [
            Data(#"{"hook_event_name":"SubagentStop","session_id":"s"}"#.utf8),
            Data(#"{"hook_event_name":"Notification","session_id":"s"}"#.utf8),
        ]
        let arrival = Date(timeIntervalSince1970: 1_750_000_000)
        let events = SessionsFeed.normalize(lines, arrival: arrival)

        #expect(events.count == 2)
        #expect(events[0].timestamp < events[1].timestamp,
                "each line must carry a strictly increasing stamp in file order")

        // End-to-end through the reconciler: the whole batch coalesces into one
        // burst, and the LAST-written Notification must decide it — with equal
        // stamps the neutral SubagentStop would win and the attention signal
        // would vanish.
        let store = HookSessionStore(stallThreshold: 600)
        store.ingest(events)
        #expect(store.entry(for: "s")?.state == .waitingForInput,
                "the last event of the batch (Notification) must be dominant")
    }
}
