import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// The reconciled-entry → board-card seam between the observe-only event-file sink
/// (DD-002) and the board. After the HTTP cutover, sessions arrive as reconciled
/// `HookSessionStore.Entry` values (not a `/sessions` JSON body); these drive the
/// REAL mapping (`SessionsFeed.cards(from:)`) so an entry/board drift is caught
/// before it reaches an NSView. Each hook-observed session is a human-launched
/// Claude Code run we only watch (flow B), labelled by repo (falling back to id).
struct SessionsFeedTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func entry(_ id: String, _ state: CardState, dir: String?) -> HookSessionStore.Entry {
        HookSessionStore.Entry(sessionID: id, state: state, updatedAt: now, projectDir: dir)
    }

    @Test func mapsEachEntryToAWatchedFlowBClaudeCard() {
        let cards = SessionsFeed.cards(from: [entry("sess-normal", .running, dir: "/repo")])
        #expect(cards.count == 1)

        let normal = cards[0]
        #expect(normal.sessionID == "sess-normal")
        #expect(normal.projectDir == "/repo")
        #expect(normal.state == .running)
        // Every hook-observed session is a human-launched Claude Code run we only watch.
        #expect(normal.agent == .claude)
        #expect(normal.flow == .b)
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
            .appendingPathComponent("ghostling-feed-\(UUID().uuidString).jsonl")
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
    @Test @MainActor func fsWrite_triggersReadWithoutBackstop() throws {
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
        #expect(snapshot.contains { $0.sessionID == "A" })
        #expect(!snapshot.contains { $0.sessionID == "B" })

        // A new hook lands after start; with the backstop disabled it can reach the
        // board only via the FS-watch trigger.
        try appendLine(sessionStart("B"), to: file)
        poller.fireWatchForTesting()   // == "the FS-object source fired on .write"

        #expect(snapshot.contains { $0.sessionID == "B" },
                "the read must have fired because the FS-watch fired (backstop disabled)")
    }
}
