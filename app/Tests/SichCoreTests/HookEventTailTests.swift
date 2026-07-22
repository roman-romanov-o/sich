import Foundation
import SichCore
import Testing

/// The durable, incremental, rotation-safe tail over the append-only hook event file
/// (US-001 / DD-002). These pin two invariants the board's freshness depends on:
///
/// - **TC-INT-001** — a read after ONE append returns only that event and advances the
///   offset by exactly its byte length (regression guard against a whole-file re-read).
/// - **TC-UNIT-003** — rotation to a fresh file (a different inode, even one already
///   grown past the old offset) loses no event and produces no duplicate.
///
/// Harness rules (inherited from `HookSinkTests`): never spawns `claude -p`, opens no
/// port, never touches the real `~/.sich`. Each case builds its own event file
/// and offset sidecar under the temp dir.
@Suite(.serialized)
struct HookEventTailTests {

    // MARK: - Fixture helpers

    private func makeEventsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-tail-\(UUID().uuidString).jsonl")
    }

    /// Append one newline-terminated line under `O_APPEND`, exactly as the forwarder.
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

    private func decode(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// The persisted read offset. Tolerant of both the `inode:offset` checkpoint and a
    /// legacy plain-int offset file — the test asserts the numeric offset only.
    private func savedOffset(_ url: URL) -> Int {
        let raw = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = raw.lastIndex(of: ":") {
            return Int(raw[raw.index(after: colon)...]) ?? -1
        }
        return Int(raw) ?? -1
    }

    private func cleanup(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - TC-INT-001: incremental read returns only the appended bytes

    @Test func readNew_returnsOnlyAppendedEvents() throws {
        let file = makeEventsFile()
        let offset = file.appendingPathExtension("offset")
        defer { cleanup(file, offset) }

        let first = #"{"hook_event_name":"SessionStart","session_id":"S"}"#
        try append(first, to: file)
        let tail = HookEventTail(file: file, offsetStore: offset)
        #expect(tail.poll().map(decode) == [first])
        let afterFirst = savedOffset(offset)

        // ONE more event appended after the first drain.
        let second = #"{"hook_event_name":"Stop","session_id":"S"}"#
        try append(second, to: file)

        // The second read returns ONLY the appended event — not the whole history.
        #expect(tail.poll().map(decode) == [second])
        // And the offset advanced by EXACTLY that event's byte length (newline
        // included): a whole-file `Data(contentsOf:)` read would not preserve this
        // incremental delta (read cost independent of file size).
        #expect(savedOffset(offset) - afterFirst == (second + "\n").utf8.count)
        // A third read with nothing appended is empty — no re-scan of history.
        #expect(tail.poll().isEmpty)
    }

    // MARK: - TC-UNIT-003: rotation re-arms by inode (no loss, no dup)

    @Test func rotation_reArmsNoLossNoDup() throws {
        let file = makeEventsFile()
        let offset = file.appendingPathExtension("offset")
        let rotated = file.appendingPathExtension("1")
        defer { cleanup(file, offset, rotated) }

        let e1 = #"{"hook_event_name":"SessionStart","session_id":"S"}"#
        try append(e1, to: file)
        let tail = HookEventTail(file: file, offsetStore: offset)
        #expect(tail.poll().map(decode) == [e1])

        // Rotate: move the current file aside, then create a NEW file (a fresh inode)
        // that is ALREADY LARGER than the old offset. With the old `saved > fileSize`
        // guard this would resume mid-file and skip the new head; the inode reset must
        // read it from the top instead.
        try FileManager.default.moveItem(at: file, to: rotated)
        let e2 = #"{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Edit"}"#
        let e3 = #"{"hook_event_name":"Stop","session_id":"S"}"#
        try Data((e2 + "\n" + e3 + "\n").utf8).write(to: file)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0)
                > savedOffset(offset), "the rotated file must be larger than the old offset")

        // No loss: both new-file events surface. No dup: the pre-rotation event is not
        // re-emitted.
        let after = tail.poll().map(decode)
        #expect(after == [e2, e3])
        #expect(!after.contains(e1))
        // Steady state on the new inode: a further append drains only the new line.
        let e4 = #"{"hook_event_name":"SessionStart","session_id":"T"}"#
        try append(e4, to: file)
        #expect(tail.poll().map(decode) == [e4])
    }
}
