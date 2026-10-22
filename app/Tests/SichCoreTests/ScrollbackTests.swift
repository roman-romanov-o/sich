import Testing

@testable import SichCore

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

    @Test("new output while scrolled up does not yank the viewport back to bottom")
    func outputWhileScrolledUpKeepsViewport() throws {
        let term = try Terminal(cols: 20, rows: 5)
        for i in 1...30 { term.write(Array("line\(i)\r\n".utf8)) }

        term.scrollViewport(delta: -10)
        let historyTop = rowText(term.snapshot(), 0)

        for i in 31...40 { term.write(Array("line\(i)\r\n".utf8)) }
        #expect(rowText(term.snapshot(), 0) == historyTop)   // still reading history
    }
}

/// The two emulator-level defects behind "I scroll and it's just blank" on local
/// cards (remote cards never showed it because tmux owns their scrollback):
/// a single resize that shrinks BOTH dimensions corrupted the whole history in the
/// pinned libghostty, and a 1000-*byte* scrollback budget let every page prune drag
/// a parked viewport along.
@Suite("Terminal scrollback survives resize and long output")
struct ScrollbackIntegrityTests {

    private func viewport(_ term: Terminal) -> [String] {
        let grid = term.snapshot()
        return (0..<grid.rows).map { row in
            String(String.UnicodeScalarView(
                (0..<grid.cols).compactMap { grid.cells[row * grid.cols + $0].scalar }
            )).trimmingCharacters(in: .whitespaces)
        }
    }

    private func nonBlankRows(_ term: Terminal) -> Int {
        viewport(term).filter { !$0.isEmpty }.count
    }

    private func fill(_ term: Terminal, _ range: ClosedRange<Int>) {
        for i in range { term.write(Array("line \(i)\r\n".utf8)) }
    }

    @Test("shrinking cols and rows in one resize keeps the live screen and the history")
    func shrinkBothDimensionsKeepsHistory() throws {
        let term = try Terminal(cols: 120, rows: 40)
        fill(term, 1...600)
        let historyBefore = term.scrollbackRows

        term.resize(cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 16)

        #expect(nonBlankRows(term) >= 23)                      // live screen intact
        #expect(viewport(term).first == "line 578")
        #expect(term.scrollbackRows == historyBefore + 16)     // 16 rows moved up, nothing invented
        term.scrollViewport(delta: -100)
        #expect(viewport(term).first == "line 478")            // history is real content
        #expect(nonBlankRows(term) == 24)
    }

    @Test("a viewport parked in history survives a both-dimension shrink")
    func parkedViewportSurvivesShrink() throws {
        let term = try Terminal(cols: 120, rows: 40)
        fill(term, 1...600)
        term.scrollViewport(delta: -100)
        let parkedTop = viewport(term).first

        term.resize(cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 16)

        #expect(term.snapshot().cursor == nil)                 // still parked
        #expect(viewport(term).first == parkedTop)
        #expect(nonBlankRows(term) == 24)
    }

    @Test("long output keeps far more than two pages of history")
    func historyIsNotClampedToTwoPages() throws {
        let term = try Terminal(cols: 120, rows: 40)
        fill(term, 1...5000)
        #expect(term.scrollbackRows == 4961)
    }

    @Test("new output does not drag a parked viewport when pages are pruned")
    func pruneDoesNotDragParkedViewport() throws {
        let term = try Terminal(cols: 120, rows: 40)
        fill(term, 1...600)
        term.scrollViewport(delta: -100)
        let parkedTop = viewport(term).first

        fill(term, 601...4000)                                 // several page prunes under the old cap

        #expect(viewport(term).first == parkedTop)
        #expect(nonBlankRows(term) == 40)
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
