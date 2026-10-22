import AppKit
import SichCore
import Testing

@testable import SichApp

/// Pixel-smooth scrolling: a precise (trackpad) wheel moves the viewport by
/// fractions of a row — whole rows go to the emulator at frame time, the rest
/// shifts the row stack up with the row below sliding in — and the fraction is
/// always honest: never while live, never past the top of scrollback, gone the
/// moment the user types. Idle frames pre-render the screen above. Driven with
/// real CG wheel events, as the window server would.
@MainActor
struct TerminalSmoothScrollTests {
    private func makeSurface(history: Int = 400, script: String? = nil) throws -> (TerminalSurface, PTYSession) {
        let pty = try PTYSession(
            // `end` keeps the last live row non-blank, so the row that slides in
            // below a half-scrolled viewport is a painted one.
            command: ["/bin/zsh", "-c", "\(script ?? "seq 1 \(history)"); printf end; sleep 30"],
            rows: 24, cols: 80)
        try pty.start()
        pty.setNonBlocking()
        let surface = TerminalSurface(session: pty)
        surface.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        surface.startReading()
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, (try? pty.terminal.plainText())?.contains("end") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        settle()
        return (surface, pty)
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    /// A precise trackpad event: `pixels` points, continuous deltas.
    private func trackpadEvent(pixels: Int32) throws -> NSEvent {
        let backing = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: pixels, wheel2: 0, wheel3: 0))
        backing.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return try #require(NSEvent(cgEvent: backing))
    }

    /// The surface sizes the emulator to its own frame (font 20pt in 400pt), so
    /// the row count is read back from the grid rather than assumed.
    private func rows(_ surface: TerminalSurface) -> Int { surface.gridForTesting.rows }

    private func cellHeight(_ surface: TerminalSurface) -> CGFloat {
        surface.rowHostForTesting.frame.height / CGFloat(rows(surface))
    }

    @Test("half a row of trackpad motion leaves the viewport in history, shifted by half a row")
    func halfRowSwipeShiftsTheStackByHalfARow() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }
        let rowHeight = cellHeight(surface)
        // Ghostty's 2x trackpad sensitivity: a quarter row of pixels is half a row.
        surface.scrollWheel(with: try trackpadEvent(pixels: Int32((rowHeight / 4).rounded())))
        settle()

        let fraction = surface.scrollFractionForTesting
        #expect(surface.isViewingScrollback)
        #expect(fraction > 0.3 && fraction < 0.7)
        let host = surface.rowHostForTesting
        #expect(abs(host.bounds.origin.y - fraction * rowHeight) < 0.001)
        #expect(host.layer!.sublayers![rows(surface)].isHidden == false)   // the row below slid in
        #expect(host.rowCount == rows(surface) + 1)
    }

    @Test("scrolling back down onto the live screen snaps the fraction to zero")
    func scrollingPastLiveClampsToZero() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }
        let quarterRow = Int32((cellHeight(surface) / 4).rounded())
        surface.scrollWheel(with: try trackpadEvent(pixels: quarterRow))
        settle()
        #expect(surface.scrollFractionForTesting > 0)

        surface.scrollWheel(with: try trackpadEvent(pixels: -quarterRow * 3))   // past the bottom
        settle()
        #expect(surface.scrollFractionForTesting == 0)
        #expect(surface.isViewingScrollback == false)
        #expect(surface.rowHostForTesting.bounds.origin.y == 0)
    }

    @Test("a swipe past the top of scrollback does not leave a fraction hiding the first row")
    func scrollingPastTopClampsToZero() throws {
        let (surface, pty) = try makeSurface(history: 30)   // only a few history rows
        defer { surface.stopReading(); pty.terminate() }
        let rowHeight = cellHeight(surface)
        surface.scrollWheel(with: try trackpadEvent(pixels: Int32((rowHeight * 40).rounded())))
        settle()
        #expect(surface.isViewingScrollback)
        #expect(surface.scrollFractionForTesting == 0)
        #expect(surface.gridForTesting.cell(col: 0, row: 0).scalar == "1")   // the first row is fully shown
    }

    @Test("typing while fractionally scrolled returns to the live bottom with no offset")
    func typingDropsTheFraction() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }
        surface.scrollWheel(with: try trackpadEvent(pixels: Int32((cellHeight(surface) / 4).rounded())))
        settle()
        #expect(surface.scrollFractionForTesting > 0)

        let backing = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0x00, keyDown: true))
        surface.keyDown(with: try #require(NSEvent(cgEvent: backing)))
        settle()
        #expect(surface.scrollFractionForTesting == 0)
        #expect(surface.isViewingScrollback == false)
        #expect(surface.rowHostForTesting.bounds.origin.y == 0)
    }

    /// Claude Code rewrites its bottom line between any two frames (spinner, token
    /// counter). The fraction must come from how far the emulator actually moved,
    /// not from recognising the previous frame's rows in the new one — that
    /// comparison fails under a repaint and the viewport jumps to a whole row.
    @Test("a child repainting between frames does not knock the fraction off")
    func repaintBetweenFramesKeepsTheFraction() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }
        let rowHeight = cellHeight(surface)
        let pixels = Int32((rowHeight / 4).rounded())           // about half a row per swipe
        let step = CGFloat(pixels) * 2 / rowHeight
        let live = pty.terminal.viewportOffset
        for swipe in 1...6 {
            // The repaint: rewrite a line three rows above the cursor, as a TUI
            // frame does, then put the cursor back.
            pty.terminal.write(Array("\u{1B}[3A\r\u{1B}[2Kspin \(swipe)\u{1B}[3B".utf8))
            surface.scrollWheel(with: try trackpadEvent(pixels: pixels))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let rowsUp = CGFloat(live - pty.terminal.viewportOffset) - surface.scrollFractionForTesting
            #expect(abs(rowsUp - step * CGFloat(swipe)) < 0.01, "swipe \(swipe)")
        }
    }

    /// Claude Code's working-state repaint walks the cursor up the active screen
    /// every frame. A viewport scrolled less than a screen still shows most of the
    /// active area, so the cursor is often inside it — that is not "live", and the
    /// idle-frame prefetch must not treat it as live and snap back to the bottom.
    @Test("a child cursor inside a partly scrolled viewport does not snap it back to live")
    func cursorInsideAPartlyScrolledViewportIsNotLive() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }
        let rowHeight = cellHeight(surface)
        let threeRows = Int32((rowHeight * 1.5).rounded())
        let live = pty.terminal.viewportOffset
        surface.scrollWheel(with: try trackpadEvent(pixels: threeRows))
        settle()
        #expect(surface.isViewingScrollback)

        // The repaint: cursor up to the second row of the active screen, which the
        // viewport (three rows into history) still shows; the next wheel tick and
        // the idle frame after it must leave the viewport where the user put it.
        pty.terminal.write(Array("\u{1B}[\(rows(surface) - 2)A\rspin".utf8))
        surface.scrollWheel(with: try trackpadEvent(pixels: threeRows))
        settle()
        #expect(surface.displayFrameForTesting() == false)   // idle frame: the prefetch runs here
        #expect(surface.isViewingScrollback)
        let rowsUp = CGFloat(live - pty.terminal.viewportOffset) - surface.scrollFractionForTesting
        #expect(abs(rowsUp - 6) < 0.05)
        #expect(surface.gridForTesting.cursor != nil)         // the cursor really is on screen
    }

    /// Scrollback from a TUI is full of blank bands, where rows are indistinguishable
    /// — a restore that looks for the previous rows can land one row off.
    @Test("an idle frame in history puts the viewport back exactly, even inside a blank band")
    func idleFrameInHistoryRestoresTheViewportExactly() throws {
        let (surface, pty) = try makeSurface(
            script: "seq 1 40; for i in {1..40}; do echo; done; seq 41 80")
        defer { surface.stopReading(); pty.terminate() }
        let rowHeight = cellHeight(surface)
        surface.scrollWheel(with: try trackpadEvent(pixels: Int32((rowHeight * 25).rounded())))   // 50 rows up
        settle()
        #expect(surface.isViewingScrollback)
        let offset = pty.terminal.viewportOffset
        #expect(surface.gridForTesting.cell(col: 0, row: 0).scalar == nil)   // parked in the blank band

        #expect(surface.displayFrameForTesting() == false)   // idle frame: the prefetch runs here
        #expect(pty.terminal.viewportOffset == offset)
        #expect(pty.terminal.snapshot().cells == surface.gridForTesting.cells)
    }

    @Test("an idle frame after a viewport change pre-renders the screen above and leaves the viewport alone")
    func idleFramePrefetchesTheScreenAbove() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }
        let cache = surface.rowCacheForTesting
        cache.removeAll()                                      // forget the rows that streamed past
        surface.installGridForTesting(surface.gridForTesting)  // the live screen alone is cached
        let before = cache.count
        #expect(before <= rows(surface))

        surface.scrollWheel(with: try trackpadEvent(pixels: 1))   // a viewport refresh arms the prefetch
        surface.scrollWheel(with: try trackpadEvent(pixels: -1))
        settle()
        #expect(surface.isViewingScrollback == false)
        #expect(surface.displayFrameForTesting() == false)   // idle frame: the prefetch runs here
        #expect(cache.count >= before + rows(surface) - 1)    // a screen of history rows got painted
        #expect(surface.isViewingScrollback == false)
        #expect(pty.terminal.snapshot().cursor != nil)       // the viewport was put back on live
    }
}
