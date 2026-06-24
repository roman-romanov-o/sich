import Testing
@testable import GhostlingCore

// Swift port of the Phase 00 spike: prove the vendored xcframework + the Swift
// binding + the in-app PTY read work end-to-end. Spawn a real process in a pty,
// read its output in-process, feed libghostty-vt, read the screen back.

@Suite("In-process PTY read via libghostty-vt")
struct PTYReadTests {

    @Test("echo output is read in-process and rendered by the emulator")
    func echoIsRenderedFromPTY() throws {
        let session = try PTYSession(command: ["/bin/echo", "hello-ghostty"])
        try session.start()
        let bytes = session.drainToEOF()
        session.finish()

        #expect(bytes > 0)
        let screen = try session.terminal.plainText()
        #expect(screen.contains("hello-ghostty"))
    }

    @Test("a terminal can be written to directly and rendered")
    func directWriteRenders() throws {
        let terminal = try Terminal(cols: 80, rows: 24)
        terminal.write(Array("plain-vt-write".utf8))
        #expect(try terminal.plainText().contains("plain-vt-write"))
    }

    @Test("VT escape sequences are interpreted, not echoed literally")
    func escapeSequencesAreInterpreted() throws {
        let terminal = try Terminal(cols: 80, rows: 24)
        // Bold "ok" then reset; the SGR bytes must not survive into plain text.
        terminal.write(Array("\u{1B}[1mok\u{1B}[0m".utf8))
        let screen = try terminal.plainText()
        #expect(screen.contains("ok"))
        #expect(!screen.contains("\u{1B}"))
    }
}
