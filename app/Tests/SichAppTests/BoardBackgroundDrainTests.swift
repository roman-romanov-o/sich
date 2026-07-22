import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// Reproduces the reported bug: open a task, run something long-running in it, then
/// LEAVE the task (back to the board) — and the work silently stalls, only resuming
/// when you reopen the task.
///
/// Root cause (see `PTYBackpressureTests`): the pty read loop lived ONLY inside the
/// drilled-in `TerminalSurface`, so a session that is not drilled in had nobody
/// draining its pty; the child filled the kernel buffer and blocked on `write()`.
/// The board must drain every owned session continuously — whether or not its
/// terminal is on screen — exactly as tmux/screen keep off-screen panes alive.
@MainActor
struct BoardBackgroundDrainTests {
    /// A card whose child writes far more than any tty buffer, then touches a sentinel
    /// file — reachable only once its output is being drained. Firewall-clean (`/bin/sh`,
    /// never `claude -p`).
    private func blockingSeed(sentinel: String) -> BoardSeed {
        BoardSeed(
            sessionID: "long-job", projectDir: ".", agent: .claude, flow: .b,
            state: .idle, scrollback: "",
            commandOverride: ["/bin/sh", "-c", "head -c 500000 /dev/zero; : > \(sentinel)"]
        )
    }

    private func uniqueSentinel() -> String {
        NSTemporaryDirectory() + "sich-board-drain-" + ProcessInfo.processInfo.globallyUniqueString
    }

    @Test func boardDrainsASessionYouAreNotDrilledInto() throws {
        let sentinel = uniqueSentinel()
        try? FileManager.default.removeItem(atPath: sentinel)
        let shell = BoardShell(seeds: [blockingSeed(sentinel: sentinel)])
        _ = shell.buildContentForTesting()
        shell.startSessionPump()          // the always-on drain the launch path starts
        defer {
            shell.e2eTeardown()           // stops the pump + terminates owned shells
            try? FileManager.default.removeItem(atPath: sentinel)
        }

        // We never drill in. Spin the run loop; the board's pump must keep the child
        // progressing all the way to its sentinel — without the fix it blocks forever.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline, !FileManager.default.fileExists(atPath: sentinel) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(FileManager.default.fileExists(atPath: sentinel),
                "the board must drain a not-drilled-in session so its child never blocks")
    }
}
