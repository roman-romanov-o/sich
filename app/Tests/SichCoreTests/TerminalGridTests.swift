import Testing
@testable import SichCore

// The colour/cursor render path (`Terminal.snapshot()` over the libghostty-vt
// render state) and the live-resize path are window-free, so we assert them
// directly: feed known output / resize, expect a known grid back. This is the
// one runnable check behind the new TerminalGrid wrapper.

@Suite("Terminal grid snapshot + resize")
struct TerminalGridTests {

    @Test("snapshot places written text at its cells and reports the real cursor")
    func snapshotTextAndCursor() throws {
        let terminal = try Terminal(cols: 80, rows: 24)
        terminal.write(Array("hello".utf8))
        let grid = terminal.snapshot()
        #expect(grid.cols == 80)
        #expect(grid.rows == 24)
        let row0 = (0..<5).compactMap { grid.cell(col: $0, row: 0).scalar.map(Character.init) }
        #expect(String(row0) == "hello")
        // The cursor is the emulator's real position — just past the text, not a
        // guessed end-of-line block.
        #expect(grid.cursor?.x == 5)
        #expect(grid.cursor?.y == 0)
    }

    @Test("an explicit SGR colour resolves to a non-nil cell foreground")
    func snapshotResolvesColour() throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        terminal.write(Array("\u{1b}[31mX".utf8))   // red 'X'
        let cell = terminal.snapshot().cell(col: 0, row: 0)
        #expect(cell.scalar.map(Character.init) == "X")
        #expect(cell.fg != nil)   // explicit fg → resolved RGB, not the default
    }

    @Test("SGR emphasis survives the render-state snapshot")
    func snapshotPreservesTextStyle() throws {
        let terminal = try Terminal(cols: 20, rows: 5)
        terminal.write(Array("\u{1b}[1;3;4mX\u{1b}[0m".utf8))
        let style = terminal.snapshot().cell(col: 0, row: 0).style
        #expect(style.bold)
        #expect(style.italic)
        #expect(style.underline != 0)
    }

    @Test("resize changes the grid geometry a later snapshot reports")
    func resizeChangesGeometry() throws {
        let terminal = try Terminal(cols: 80, rows: 24)
        terminal.resize(cols: 40, rows: 10, cellWidthPx: 8, cellHeightPx: 16)
        let grid = terminal.snapshot()
        #expect(grid.cols == 40)
        #expect(grid.rows == 10)
    }

    @Test("session resize reflows the emulator even before the pty is spawned")
    func sessionResizeForwardsToEmulator() throws {
        let session = try PTYSession(command: ["/bin/echo", "hi"], rows: 24, cols: 80)
        session.resize(rows: 10, cols: 30, cellWidthPx: 8, cellHeightPx: 16)  // masterFD < 0: emulator-only
        let grid = session.terminal.snapshot()
        #expect(grid.cols == 30)
        #expect(grid.rows == 10)
    }
}
