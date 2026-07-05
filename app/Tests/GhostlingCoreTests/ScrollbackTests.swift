import Testing

@testable import GhostlingCore

/// Viewport scrollback: after feeding more lines than the screen holds, scrolling
/// the viewport up must reveal history in the snapshot, and scrolling to bottom
/// must return to the live screen. This is the emulator-level contract the
/// `TerminalSurface.scrollWheel` path relies on.
@Suite("Terminal viewport scrollback")
struct ScrollbackTests {

    private func rowText(_ grid: TerminalGrid, _ row: Int) -> String {
        String(String.UnicodeScalarView(
            (0..<grid.cols).compactMap { grid.cells[row * grid.cols + $0].scalar }
        )).trimmingCharacters(in: .whitespaces)
    }

    @Test("scrolling up reveals history; scrolling to bottom restores the live screen")
    func scrollUpAndBack() throws {
        let term = try Terminal(cols: 20, rows: 5)
        for i in 1...30 { term.write(Array("line\(i)\r\n".utf8)) }

        let live = term.snapshot()
        let liveTop = rowText(live, 0)

        term.scrollViewport(delta: -10)
        let scrolled = term.snapshot()
        #expect(rowText(scrolled, 0) != liveTop)          // history is showing
        #expect(rowText(scrolled, 0).hasPrefix("line"))   // and it's real content

        term.scrollViewportToBottom()
        #expect(rowText(term.snapshot(), 0) == liveTop)   // back to the live view
    }
}

/// The paste path's mode probe: bracketed paste reflects DEC 2004 as the child
/// sets/resets it.
@Suite("Bracketed paste mode probe")
struct BracketedPasteTests {
    @Test func reflectsMode2004() throws {
        let term = try Terminal(cols: 20, rows: 5)
        #expect(!term.bracketedPasteEnabled)
        term.write(Array("\u{1B}[?2004h".utf8))
        #expect(term.bracketedPasteEnabled)
        term.write(Array("\u{1B}[?2004l".utf8))
        #expect(!term.bracketedPasteEnabled)
    }
}
