import XCTest
@testable import SichCore

/// The app IS the terminal emulator (DD-001), so pty children must receive the
/// terminal identity from the spawn path itself — never laundered from however the
/// app happened to be launched. When TERM is absent (Finder, `open`, this test
/// harness), zsh silently disables its line editor: backspace echoes as a literal
/// byte the emulator renders as *forward* cursor motion, and every
/// capability-checking CLI (claude included) strips its colors. Both shipped as
/// user-visible regressions; these tests pin the spawn-path guarantee with a real
/// child process.
final class PtyChildEnvironmentE2ETests: XCTestCase {
    private func drain(_ pty: PTYSession, for seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = pty.pumpAvailable()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testChildAlwaysSeesTerminalIdentity() throws {
        let pty = try PTYSession(
            command: ["/bin/sh", "-c", "echo TERM=$TERM COLORTERM=$COLORTERM"],
            rows: 10, cols: 60)
        try pty.start()
        defer { pty.terminate() }
        pty.setNonBlocking()
        drain(pty, for: 1.0)
        let screen = (try? pty.terminal.plainText()) ?? ""
        XCTAssertTrue(screen.contains("TERM=xterm-256color"), "child TERM missing: \(screen)")
        XCTAssertTrue(screen.contains("COLORTERM=truecolor"), "child COLORTERM missing: \(screen)")
    }

    func testBackspaceErasesAtRealZshPrompt() throws {
        let pty = try PTYSession(command: ["/bin/zsh", "-f"], rows: 10, cols: 40)
        try pty.start()
        defer { pty.terminate() }
        pty.setNonBlocking()
        drain(pty, for: 1.5)
        pty.send(Array("abc".utf8))
        drain(pty, for: 0.7)
        let before = pty.terminal.snapshot()
        XCTAssertTrue(((try? pty.terminal.plainText()) ?? "").hasSuffix("abc"))

        pty.send([0x7F])
        drain(pty, for: 0.7)
        let after = pty.terminal.snapshot()
        let screen = (try? pty.terminal.plainText()) ?? ""
        XCTAssertTrue(screen.hasSuffix("ab"), "backspace did not erase: \(screen)")
        if let b = before.cursor, let a = after.cursor {
            XCTAssertEqual(a.x, b.x - 1, "cursor did not move back one cell")
        } else {
            XCTFail("cursor missing from snapshot")
        }
    }
}
