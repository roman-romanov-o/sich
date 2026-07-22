import Foundation

/// A durable tail over the append-only hook event file (DD-002). Each `poll()`
/// returns the new whole lines appended since a persisted byte offset and advances
/// that offset, so the app drains exactly once across relaunches (US-003 AC4).
///
/// Watcher discipline: read-only. It opens the file for reading, never writes it,
/// and spawns nothing — the only write is the small sidecar offset file.
///
/// Edge handling (US-003 edges 1, 2, 4; US-001 AC3):
/// - Resume from the persisted offset; no reprocessing on relaunch.
/// - Rotation to a fresh file (inode changed — even one already grown past the old
///   offset) → reset to 0; no head skipped, no crash. Keyed on inode identity, not
///   on `saved > fileSize`, which silently missed a larger rotated file (TC-UNIT-003).
/// - In-place truncation (`offset > fileSize`, same inode) → reset to 0.
/// - Read only up to the last newline; a partial trailing line waits for completion.
/// `Sendable` because all stored state is immutable (two URLs); the mutable state
/// is on disk. Callers must still serialize `poll()` calls (the offset file is
/// read-modify-write) — `SessionsPoller` guarantees one in-flight drain at a time.
public final class HookEventTail: Sendable {
    private let file: URL
    private let offsetStore: URL

    /// - Parameters:
    ///   - file: the append-only event file (`~/.sich/events.jsonl`).
    ///   - offsetStore: where the last processed byte offset is persisted (next to
    ///     the file). Defaults to `<file>.offset`.
    public init(file: URL, offsetStore: URL? = nil) {
        self.file = file
        self.offsetStore = offsetStore ?? file.appendingPathExtension("offset")
    }

    /// Return the new whole lines since the last poll, advancing the persisted
    /// offset past them. An absent file yields `[]` (nothing to drain yet).
    ///
    /// Reads ONLY the bytes appended since the offset (seek → read-to-end), not the
    /// whole file: the event file grows unbounded (megabytes), so a whole-file
    /// `Data(contentsOf:)` per poll would be quadratic churn. (The drain itself runs
    /// off the main actor — see `SessionsPoller` — but a rotation still re-reads a
    /// whole new file in one batch, so incremental reads stay load-bearing.)
    public func poll() -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return [] }
        let inode = currentInode(handle)
        let start = resolveStart(fileSize: Int(fileSize), inode: inode)
        guard UInt64(start) < fileSize else { return [] }   // caught up: nothing new
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let tail = try? handle.readToEnd() else { return [] }
        let (lines, consumed) = wholeLines(in: tail, from: 0)
        persistCheckpoint(inode: inode, offset: start + consumed)
        return lines
    }

    // MARK: - Offset / rotation identity

    /// One persisted read position: the source file's `inode` and the byte `offset`
    /// drained so far. Keeping the inode is what makes rotation safe (US-001 AC3) —
    /// the offset alone can't tell a grown same-file from a fresh rotated one.
    private struct Checkpoint {
        let inode: UInt64?   // nil ⇒ legacy pre-inode offset file: resume, don't reset
        let offset: Int
    }

    /// The byte offset to read from. Reset to 0 when the file's identity changed —
    /// the inode differs (rotation to a fresh file, even one already grown past the
    /// old offset — TC-UNIT-003) or the saved offset points past EOF (in-place
    /// truncation — US-003 edge 2). Otherwise resume from the saved offset.
    private func resolveStart(fileSize: Int, inode: UInt64) -> Int {
        guard let saved = loadCheckpoint() else { return 0 }
        if let savedInode = saved.inode, savedInode != inode { return 0 }
        return saved.offset > fileSize ? 0 : saved.offset
    }

    /// The inode of the currently-open handle (not the path) — reading it from the fd
    /// avoids a rotation race between resolving and reading.
    private func currentInode(_ handle: FileHandle) -> UInt64 {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return 0 }
        return UInt64(info.st_ino)
    }

    private func loadCheckpoint() -> Checkpoint? {
        guard let raw = try? String(contentsOf: offsetStore, encoding: .utf8) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ":", maxSplits: 1)
        if parts.count == 2, let inode = UInt64(parts[0]), let offset = Int(parts[1]) {
            return Checkpoint(inode: inode, offset: offset)
        }
        if let offset = Int(text) { return Checkpoint(inode: nil, offset: offset) }
        return nil
    }

    private func persistCheckpoint(inode: UInt64, offset: Int) {
        try? "\(inode):\(offset)".write(to: offsetStore, atomically: true, encoding: .utf8)
    }

    // MARK: - Line framing

    /// Split `data[from...]` into whole newline-terminated lines, returning the
    /// lines (newline stripped) and the number of bytes consumed (up to the last
    /// newline only — a partial trailing line is left for the next poll, edge 4).
    private func wholeLines(in data: Data, from start: Int) -> (lines: [Data], consumed: Int) {
        guard start <= data.count, let lastNewline = lastNewlineIndex(in: data, from: start) else {
            return ([], 0)
        }
        let frame = Array(data[start..<lastNewline])
        let lines = frame
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
        return (lines, (lastNewline + 1) - start)
    }

    /// Index of the last `\n` at or after `start`, or `nil` if there is none yet.
    private func lastNewlineIndex(in data: Data, from start: Int) -> Int? {
        guard start < data.count else { return nil }
        let newline: UInt8 = 0x0A
        return data[start...].lastIndex(of: newline)
    }
}
