import AppKit
import SichCore
import Testing

@testable import SichApp

/// ⌘↑ / ⌘↓ jump the viewport between the user's prompts in a Claude Code
/// transcript, so finding "what did I ask" is a keystroke, not a scroll hunt.
/// Driven through the key-equivalent path with real key events.
@MainActor
struct TerminalPromptJumpTests {
    /// A transcript look-alike: two prompt echoes separated by long answers and a
    /// live input box (`❯` + non-breaking space, cursor after it) at the bottom.
    private func makeSurface() throws -> (TerminalSurface, PTYSession) {
        let script = "echo '❯ first question'; seq 1 60; echo '❯ second question'; seq 61 120; "
            + "printf '❯\\u00a0'"
        let pty = try PTYSession(command: ["/bin/zsh", "-c", "\(script); sleep 30"], rows: 24, cols: 80)
        try pty.start()
        pty.setNonBlocking()
        let surface = TerminalSurface(session: pty)
        surface.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        surface.startReading()
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, (try? pty.terminal.plainText())?.contains("120") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        settle()
        return (surface, pty)
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }

    private func commandArrow(up: Bool) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: up ? "\u{F700}" : "\u{F701}",
            charactersIgnoringModifiers: up ? "\u{F700}" : "\u{F701}", isARepeat: false,
            keyCode: up ? 126 : 125))
    }

    private func topRow(_ surface: TerminalSurface) -> String {
        let grid = surface.gridForTesting
        return String(String.UnicodeScalarView((0..<grid.cols).compactMap { grid.cells[$0].scalar }))
            .trimmingCharacters(in: .whitespaces)
    }

    @Test("⌘↑ walks back prompt by prompt and stops at the first; ⌘↓ walks forward and ends live")
    func commandArrowsWalkThePrompts() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }
        #expect(!surface.isViewingScrollback)

        #expect(surface.performKeyEquivalent(with: try commandArrow(up: true)))
        settle()
        #expect(surface.isViewingScrollback)
        #expect(topRow(surface) == "❯ second question")

        #expect(surface.performKeyEquivalent(with: try commandArrow(up: true)))
        settle()
        #expect(topRow(surface) == "❯ first question")

        #expect(surface.performKeyEquivalent(with: try commandArrow(up: true)))   // nothing above: stays
        settle()
        #expect(topRow(surface) == "❯ first question")

        #expect(surface.performKeyEquivalent(with: try commandArrow(up: false)))
        settle()
        #expect(topRow(surface) == "❯ second question")

        #expect(surface.performKeyEquivalent(with: try commandArrow(up: false)))   // past the last: live
        settle()
        #expect(!surface.isViewingScrollback)
        #expect(surface.scrollFractionForTesting == 0)
    }

    @Test("a jump lands on a whole row even mid-fraction, and the child never sees the chord")
    func jumpDropsTheFractionAndStaysLocal() throws {
        let (surface, pty) = try makeSurface()
        defer { surface.stopReading(); pty.terminate() }
        var sent = 0
        pty.onInput = { sent += $0.count }
        let backing = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0))
        backing.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        surface.scrollWheel(with: try #require(NSEvent(cgEvent: backing)))
        settle()
        #expect(surface.scrollFractionForTesting > 0)

        #expect(surface.performKeyEquivalent(with: try commandArrow(up: true)))
        settle()
        #expect(surface.scrollFractionForTesting == 0)
        #expect(surface.rowHostForTesting.bounds.origin.y == 0)
        #expect(topRow(surface) == "❯ second question")
        #expect(sent == 0)
    }
}
