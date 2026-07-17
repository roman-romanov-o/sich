import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// The reconciler's JSONL fallback reaching the live board (US-002 AC#1 / TC-INT-010).
/// A hook `Stop` can be raced or dropped; the Claude transcript's `turn_completed`
/// record (a lower-precedence JSONL signal that never overrides a live hook) lands on
/// the SAME event-file tail tagged `"source":"jsonl"`, so a session still converges to
/// its end-of-turn `idle` instead of locking in `running`. Driven through the REAL poll path
/// (`SessionsPoller` → `SessionsFeed.normalize` → `HookSessionStore`) so a wiring gap
/// is caught before it reaches an NSView.
///
/// Harness rules (inherited from `SessionsFeedTests`): builds its own event file under
/// the temp dir, never touches `~/.ghostling`, spawns nothing, opens no port. Ordering
/// is deterministic via explicit epoch timestamps in the JSON — never wall-clock.
@MainActor
struct ReconcilerTests {
    private let base = 1_750_000_000.0

    private func makeEventsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostling-recon-\(UUID().uuidString).jsonl")
    }

    private func append(_ line: String, to file: URL) throws {
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

    private func cleanup(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private func hook(_ name: String, _ id: String, _ ts: Double) -> String {
        #"{"hook_event_name":"\#(name)","session_id":"\#(id)","timestamp":\#(ts)}"#
    }

    /// A transcript `turn_completed` record on the JSONL fallback stream (`source:jsonl`).
    private func jsonlStop(_ id: String, _ ts: Double) -> String {
        #"{"source":"jsonl","type":"turn_completed","session_id":"\#(id)","timestamp":\#(ts)}"#
    }

    // MARK: - TC-INT-010: dropped Stop recovered via JSONL fallback

    @Test func droppedStop_recoveredViaJSONL() throws {
        let file = makeEventsFile()
        let offset = file.appendingPathExtension("offset")
        defer { cleanup(file, offset) }

        // A live run: SessionStart + a tool call → running.
        try append(hook("SessionStart", "S", base), to: file)
        try append(hook("PreToolUse", "S", base + 1), to: file)
        // The Stop hook is DROPPED (never written) — the classic raced/lost-hook case.
        // The transcript's turn_completed lands on the JSONL fallback stream and
        // reconstructs the missing exit.
        try append(jsonlStop("S", base + 15), to: file)

        var snapshot: [BoardCard] = []
        // Backstop disabled → the cold-start drain is the only read.
        let poller = SessionsPoller(eventsFile: file, interval: 86_400) { snapshot = $0 }
        poller.start()
        defer { poller.stop() }

        let card = try #require(snapshot.first { $0.sessionID == "S" })
        #expect(card.state == .idle,
                "a dropped Stop must be recovered from the JSONL transcript tail (turn ended → idle)")
    }
}
