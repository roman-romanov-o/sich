import Foundation
import Testing

@testable import SichCore

/// The ROOT CAUSE of "work stops when I leave the task": a pty whose output nobody
/// reads fills the kernel's tty output buffer (tens of KB on macOS) and the child
/// then BLOCKS on `write()` — its work halts mid-flight — until something drains the
/// backlog. `claude`, which repaints its TUI continuously, fills that buffer in a
/// fraction of a second, so leaving a task freezes the agent.
///
/// This is a mechanism characterization: it proves the back-pressure directly on
/// ``PTYSession`` so the board-level wiring test (`BoardBackgroundDrainTests`) reads
/// against a proven cause, not a hypothesis.
@Suite("PTY back-pressure: an undrained child blocks on write")
struct PTYBackpressureTests {
    /// A child that writes far more than any tty buffer to stdout, THEN creates a
    /// sentinel file. It can only reach the sentinel once its writes stop blocking —
    /// i.e. once someone drains the pty. The sentinel is the observable "work progressed".
    private func blockingChild(sentinel: String) -> [String] {
        ["/bin/sh", "-c", "head -c 500000 /dev/zero; : > \(sentinel)"]
    }

    private func uniqueSentinel() -> String {
        NSTemporaryDirectory() + "sich-drain-" + ProcessInfo.processInfo.globallyUniqueString
    }

    @Test func undrainedChildBlocksThenDrainingUnblocksIt() throws {
        let sentinel = uniqueSentinel()
        try? FileManager.default.removeItem(atPath: sentinel)
        let session = try PTYSession(command: blockingChild(sentinel: sentinel))
        try session.start()
        session.setNonBlocking()
        defer {
            session.terminate()
            try? FileManager.default.removeItem(atPath: sentinel)
        }

        // Give the child time to fill the buffer and block. A blocked write stays
        // blocked, so after this pause the sentinel must still be absent.
        Thread.sleep(forTimeInterval: 0.7)
        #expect(!FileManager.default.fileExists(atPath: sentinel),
                "an undrained child must be blocked on write, never reaching its side effect")

        // Now drain continuously — the child unblocks, finishes writing, hits the sentinel.
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline, !FileManager.default.fileExists(atPath: sentinel) {
            _ = session.pumpAvailable()
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(atPath: sentinel),
                "draining the pty unblocks the child so its work completes")
    }
}
