import Testing
@testable import GhostlingCore

// `TerminalSurface` renders `Terminal.lines()`. That grid → text extraction is
// window-free, so we assert it directly (same pattern as PTYReadTests): feed
// known output, expect known lines back.

@Suite("Grid → renderable lines extraction")
struct GridTextTests {

    @Test("a single written line appears as one renderable line")
    func singleLine() throws {
        let terminal = try Terminal(cols: 80, rows: 24)
        terminal.write(Array("first-line".utf8))
        let lines = try terminal.lines()
        #expect(lines.first == "first-line")
    }

    @Test("CRLF-separated output splits into multiple lines")
    func multipleLines() throws {
        let terminal = try Terminal(cols: 80, rows: 24)
        terminal.write(Array("alpha\r\nbravo\r\ncharlie".utf8))
        let lines = try terminal.lines()
        #expect(lines.contains("alpha"))
        #expect(lines.contains("bravo"))
        #expect(lines.contains("charlie"))
    }

    @Test("an untouched terminal renders no lines")
    func emptyTerminal() throws {
        let terminal = try Terminal(cols: 80, rows: 24)
        #expect(try terminal.lines().isEmpty)
    }

    @Test("PTY output is extractable as lines, not just a blob")
    func fromPTY() throws {
        let session = try PTYSession(command: ["/bin/echo", "grid-line-marker"])
        try session.start()
        session.drainToEOF()
        session.finish()
        #expect(try session.terminal.lines().contains("grid-line-marker"))
    }
}
