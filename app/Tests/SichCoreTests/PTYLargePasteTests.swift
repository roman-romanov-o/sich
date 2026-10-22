import Foundation
import Testing

@testable import SichCore

/// The "my paste came out cropped" defect: a pty master's input queue holds ~1KB
/// (`MAX_INPUT`), and the master fd is non-blocking, so one `write()` of a big
/// paste lands only its first chunk. Everything past that must be queued and
/// flushed as the child drains — never dropped.
@Suite("PTY large paste: every byte reaches the child")
struct PTYLargePasteTests {
    /// A raw-mode child (what every TUI is) that swallows exactly `count` bytes
    /// into `out`, then creates `sentinel` — reachable only once all bytes arrived.
    private func rawSink(count: Int, out: String, sentinel: String) -> [String] {
        ["/bin/sh", "-c", "stty raw -echo; head -c \(count) > '\(out)'; : > '\(sentinel)'"]
    }

    private func tempPath(_ tag: String) -> String {
        NSTemporaryDirectory() + "sich-paste-\(tag)-" + ProcessInfo.processInfo.globallyUniqueString
    }

    @Test func aPasteLargerThanTheTtyInputQueueArrivesWhole() throws {
        let out = tempPath("out"), sentinel = tempPath("done")
        defer {
            try? FileManager.default.removeItem(atPath: out)
            try? FileManager.default.removeItem(atPath: sentinel)
        }
        let payload = Array(String(repeating: "0123456789abcdef\n", count: 3_000).utf8)  // 51KB
        let session = try PTYSession(command: rawSink(count: payload.count, out: out, sentinel: sentinel))
        try session.start()
        session.setNonBlocking()
        defer { session.terminate() }

        // Let the child switch its tty to raw mode before the paste lands.
        let rawDeadline = Date().addingTimeInterval(3.0)
        while Date() < rawDeadline {
            var t = termios()
            if tcgetattr(session.masterFD, &t) == 0, t.c_lflag & UInt(ICANON) == 0 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        session.send(payload)

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline, !FileManager.default.fileExists(atPath: sentinel) {
            _ = session.pumpAvailable()
            Thread.sleep(forTimeInterval: 0.01)
        }
        let received = FileManager.default.contents(atPath: out) ?? Data()
        #expect(received.count == payload.count,
                "child received \(received.count) of \(payload.count) pasted bytes")
        let got = Array(received)
        let firstDiff = zip(got, payload).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(firstDiff == nil,
                "first mismatch at \(firstDiff ?? -1): got \(Array(got[max(0, (firstDiff ?? 0) - 8)..<min(got.count, (firstDiff ?? 0) + 8)])) want \(Array(payload[max(0, (firstDiff ?? 0) - 8)..<min(payload.count, (firstDiff ?? 0) + 8)]))")
    }
}
