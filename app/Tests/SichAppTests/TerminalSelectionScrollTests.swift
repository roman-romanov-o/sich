import AppKit
import SichCore
import Testing

@testable import SichApp

/// A selection belongs to the text, not to the screen position: scrolling the
/// viewport must carry the highlight with its lines, ⌘C must copy the lines
/// that were selected even once they scroll off screen, and dragging after a
/// scroll must extend the selection across the history it passed. Driven with
/// real mouse and wheel events.
@MainActor
struct TerminalSelectionScrollTests {
    @MainActor
    private struct Harness {
        let surface: TerminalSurface
        let pty: PTYSession
        let window: NSWindow

        func close() {
            surface.stopReading()
            pty.terminate()
            window.orderOut(nil)
        }

        /// A real mouse event at a cell, handed to the surface's own handler (a
        /// test window is never active, so routing would eat it as a first click).
        func mouse(_ type: NSEvent.EventType, col: Int, row: Int) {
            let point = surface.convert(surface.cellCenterForTesting(col: col, row: row), to: nil)
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: surface.mouseDown(with: event)
            case .leftMouseDragged: surface.mouseDragged(with: event)
            default: surface.mouseUp(with: event)
            }
        }

        /// A classic wheel (whole lines): positive scrolls up into history.
        func wheel(lines: Int32) throws {
            let backing = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                wheel1: lines, wheel2: 0, wheel3: 0))
            surface.scrollWheel(with: try #require(NSEvent(cgEvent: backing)))
            settle()
        }
    }

    private static func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    private func settle() { Self.settle() }

    /// `seq 1 400` leaves numbered lines in scrollback; each line's text is its
    /// own whole-screen row + 1, which makes "which lines are selected" exact.
    private func makeHarness() throws -> Harness {
        let pty = try PTYSession(
            command: ["/bin/zsh", "-c", "seq 1 400; printf end; sleep 30"], rows: 24, cols: 80)
        try pty.start()
        pty.setNonBlocking()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let surface = TerminalSurface(session: pty)
        surface.frame = window.contentView!.bounds
        window.contentView!.addSubview(surface)
        window.makeKeyAndOrderFront(nil)
        surface.startReading()
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, (try? pty.terminal.plainText())?.contains("end") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        Self.settle()
        return Harness(surface: surface, pty: pty, window: window)
    }

    private func rowText(_ surface: TerminalSurface, _ row: Int) -> String {
        let grid = surface.gridForTesting
        return String(String.UnicodeScalarView(
            (0..<grid.cols).compactMap { grid.cell(col: $0, row: row).scalar }))
            .trimmingCharacters(in: .whitespaces)
    }

    @Test("scrolling after a selection keeps the selected lines, not the screen rows")
    func selectionStaysOnItsTextAcrossAScroll() throws {
        let h = try makeHarness()
        defer { h.close() }
        try h.wheel(lines: 20)   // into history, where rows hold plain numbers
        let first = rowText(h.surface, 5), second = rowText(h.surface, 6)
        h.mouse(.leftMouseDown, col: 0, row: 5)
        h.mouse(.leftMouseUp, col: 10, row: 6)
        #expect(h.surface.selectedTextForTesting == "\(first)\n\(second)")

        try h.wheel(lines: 3)
        #expect(rowText(h.surface, 5) != first, "the viewport really moved")
        #expect(h.surface.selectedTextForTesting == "\(first)\n\(second)")

        try h.wheel(lines: 30)   // the selected lines are now below the viewport
        #expect(h.surface.selectedTextForTesting == "\(first)\n\(second)")
        #expect(h.surface.isViewingScrollback)
    }

    @Test("dragging after a scroll extends the selection across the history it passed")
    func dragAfterScrollSpansHistory() throws {
        let h = try makeHarness()
        defer { h.close() }
        try h.wheel(lines: 10)
        let anchorLine = try #require(Int(rowText(h.surface, 10)))
        h.mouse(.leftMouseDown, col: 0, row: 10)
        h.mouse(.leftMouseDragged, col: 0, row: 9)
        try h.wheel(lines: 30)   // wheel while the button is held
        let focusLine = try #require(Int(rowText(h.surface, 9)))
        h.mouse(.leftMouseDragged, col: 0, row: 9)
        h.mouse(.leftMouseUp, col: 0, row: 9)

        let lines = h.surface.selectedTextForTesting.split(separator: "\n").map(String.init)
        #expect(lines.first == "\(focusLine)")
        // The anchor sits at column 0, so the last line holds its first digit only.
        #expect(lines.last == String(String(anchorLine).prefix(1)))
        #expect(lines.count == anchorLine - focusLine + 1)
    }

    @Test("reading off-screen selected lines leaves the viewport where it was")
    func copyAcrossHistoryRestoresTheViewport() throws {
        let h = try makeHarness()
        defer { h.close() }
        h.mouse(.leftMouseDown, col: 0, row: 0)
        h.mouse(.leftMouseDragged, col: 2, row: 1)
        h.mouse(.leftMouseUp, col: 2, row: 1)
        try h.wheel(lines: 60)
        let offset = h.pty.terminal.viewportOffset
        _ = h.surface.selectedTextForTesting
        #expect(h.pty.terminal.viewportOffset == offset)

        try h.wheel(lines: -200)   // back on the live screen
        #expect(!h.surface.isViewingScrollback)
        _ = h.surface.selectedTextForTesting
        #expect(h.pty.terminal.viewportOffset == h.pty.terminal.scrollbackRows)
    }
}
