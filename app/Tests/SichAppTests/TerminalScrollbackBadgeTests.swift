import AppKit
import SichCore
import Testing

@testable import SichApp

/// A trackpad swipe over a local Claude card scrolls OUR viewport into scrollback
/// (the child has no mouse tracking and is not on the alternate screen, so neither
/// forwarding branch takes the wheel). A TUI's scrollback is full of erased-frame
/// blank bands, so a parked viewport reads as a broken, "cut off" terminal. These
/// tests drive that exact path with **real dispatched events** — a CGEvent wheel and
/// a real mouse click, both delivered through `NSWindow.sendEvent` — and assert the
/// surface says so on screen and offers a way back to the live bottom.
@MainActor
struct TerminalScrollbackBadgeTests {
    /// A live surface over a child that has already produced scrollback. No window:
    /// an off-screen window's `CADisplayLink` never ticks, so the surface's headless
    /// frame fallback is what actually delivers repaints under test.
    private func makeSurface() throws -> (TerminalSurface, PTYSession) {
        let pty = try PTYSession(
            command: ["/bin/zsh", "-c", "seq 1 400; sleep 30"], rows: 24, cols: 80)
        try pty.start()
        pty.setNonBlocking()
        let surface = TerminalSurface(session: pty)
        surface.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        surface.startReading()
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, (try? pty.terminal.plainText())?.contains("400") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        settle()
        return (surface, pty)
    }

    /// Let the refresh queue and the frame clock deliver the repaint that publishes
    /// the new viewport into the surface's grid.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    /// A genuine line-unit scroll event off the CG event system — the same shape the
    /// window server hands a trackpad swipe to `scrollWheel(with:)`.
    private func wheelEvent(lines: Int32) throws -> NSEvent {
        let backing = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: lines, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: backing))
    }

    @Test func aRealWheelSwipeIntoScrollbackRaisesTheJumpToLiveBadge() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }

        #expect(surface.isViewingScrollback == false)   // parked on the live screen

        let scrollUp = try wheelEvent(lines: 6)
        surface.scrollWheel(with: scrollUp)             // the real NSEvent, not a helper
        settle()

        #expect(surface.isViewingScrollback)
        let badge = surface.scrollbackBadgeRect()
        #expect(surface.bounds.contains(badge))
    }

    @Test func aRealClickOnTheBadgeReturnsToTheLiveBottom() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }

        surface.scrollWheel(with: try wheelEvent(lines: 6))
        settle()
        #expect(surface.isViewingScrollback)

        let badge = surface.scrollbackBadgeRect()
        let inWindow = surface.convert(NSPoint(x: badge.midX, y: badge.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        surface.mouseDown(with: click)
        settle()

        #expect(surface.isViewingScrollback == false)
    }

    @Test func typingAlsoSnapsTheViewportBackToLive() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }

        surface.scrollWheel(with: try wheelEvent(lines: 6))
        settle()
        #expect(surface.isViewingScrollback)

        let backing = try #require(CGEvent(
            keyboardEventSource: nil, virtualKey: 0x00 /* a */, keyDown: true))
        let key = try #require(NSEvent(cgEvent: backing))
        surface.keyDown(with: key)
        settle()

        #expect(surface.isViewingScrollback == false)
    }
}
