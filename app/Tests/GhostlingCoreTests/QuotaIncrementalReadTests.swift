import Foundation
import Testing

@testable import GhostlingCore

/// The incremental transcript read: appended events are picked up across polls,
/// and a torn (newline-less) trailing line is deferred, not lost.
@Suite("Quota incremental transcript reads")
struct QuotaIncrementalReadTests {

    private func usageLine(at stamp: String, tokens: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(stamp)","message":{"usage":{"input_tokens":\#(tokens)}}}"# + "\n"
    }

    @Test("appended events accumulate; a torn trailing line is parsed once completed")
    func appendAndTornLine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-incr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let now = ISO8601DateFormatter().date(from: "2026-07-04T12:00:00Z")!

        try usageLine(at: "2026-07-04T11:00:00Z", tokens: 100).write(to: file, atomically: false, encoding: .utf8)
        #expect(QuotaUsageReader.readUsageEvents(now: now, projectsDir: dir).map(\.amount) == [100])

        // Append one full line + one torn line (no trailing newline yet).
        let torn = usageLine(at: "2026-07-04T11:30:00Z", tokens: 300).dropLast()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((usageLine(at: "2026-07-04T11:15:00Z", tokens: 200) + torn).utf8))
        var amounts = QuotaUsageReader.readUsageEvents(now: now, projectsDir: dir).map(\.amount).sorted()
        #expect(amounts == [100, 200])   // torn line deferred, not consumed

        try handle.write(contentsOf: Data("\n".utf8))   // complete the torn line
        try handle.close()
        amounts = QuotaUsageReader.readUsageEvents(now: now, projectsDir: dir).map(\.amount).sorted()
        #expect(amounts == [100, 200, 300])
    }
}
