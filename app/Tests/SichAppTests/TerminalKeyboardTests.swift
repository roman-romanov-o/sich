import AppKit
import SichCore
import Testing

@testable import SichApp

/// Multi-line-prompt parity with Claude Code's `/terminal-setup`: Shift+Enter (and
/// Option+Enter) must insert a literal newline (LF) rather than submit (CR), so a
/// long prompt can be composed across lines. Per the Interaction-AC Binding Rule,
/// the chord is driven by a REAL dispatched `NSEvent` through `keyDown`, and
/// delivery is asserted at the PTY write boundary (`PTYSession.onInput`) — never by
/// calling `keyInput(from:)` in isolation.
@MainActor
@Suite("Terminal Shift+Enter → newline (LF, not submit)")
struct TerminalKeyboardTests {

    private func makeSurface() throws -> (TerminalSurface, PTYSession) {
        let session = try PTYSession(command: ["/bin/cat"])
        try session.start()
        return (TerminalSurface(session: session), session)
    }

    private func enterEvent(modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
    }

    @Test("Shift+Enter sends LF (0x0A), not CR")
    func shiftEnterIsLineFeed() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        surface.keyDown(with: try enterEvent(modifiers: .shift))

        #expect(sent == [0x0A], "Shift+Enter must insert a newline, not submit")
    }

    @Test("Option+Enter also sends LF (0x0A)")
    func optionEnterIsLineFeed() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        surface.keyDown(with: try enterEvent(modifiers: .option))

        #expect(sent == [0x0A])
    }

    @Test("plain Enter still submits (CR, 0x0D)")
    func plainEnterIsCarriageReturn() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        surface.keyDown(with: try enterEvent(modifiers: []))

        #expect(sent == [0x0D], "a lone Enter must still submit")
    }

    private func deleteEvent(modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
            isARepeat: false, keyCode: 51
        ))
    }

    @Test("Cmd+Delete clears the whole line (⌃E ⌃U), so text actually disappears")
    func cmdDeleteClearsLine() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        // ⌘⌫ is a Cmd-combo → delivered on the key-equivalent path, never keyDown.
        _ = surface.performKeyEquivalent(with: try deleteEvent(modifiers: .command))

        #expect(sent == [0x05, 0x15], "jump to end (⌃E) then kill to start (⌃U)")
    }

    @Test("plain Delete still sends a single DEL (0x7F)")
    func plainDeleteIsBackspace() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        surface.keyDown(with: try deleteEvent(modifiers: []))

        #expect(sent == [0x7F], "a lone Delete stays a one-char backspace")
    }

    private func tabEvent(modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48
        ))
    }

    @Test("Shift+Tab sends xterm BackTab for Claude mode changes")
    func shiftTabIsBacktab() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        surface.keyDown(with: try tabEvent(modifiers: .shift))

        #expect(sent == [0x1B, 0x5B, 0x5A], "Shift+Tab must reach Claude as BackTab")
    }

    @Test("plain Tab still sends HT")
    func plainTabIsHT() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        surface.keyDown(with: try tabEvent(modifiers: []))

        #expect(sent == [0x09])
    }

    /// fn+↑/↓ arrive as PageUp/PageDown with AppKit's private-use characters
    /// (U+F72C/U+F72D). Unmapped they went down the pty as junk text — and they are
    /// the ONLY scroll path into Claude Code on a ConPTY host below Windows build
    /// 22523, where the wheel can never reach the child.
    private func pageEvent(keyCode: UInt16, char: Character) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: String(char), charactersIgnoringModifiers: String(char),
            isARepeat: false, keyCode: keyCode
        ))
    }

    @Test("PageUp (fn+↑) sends ESC[5~, not private-use junk")
    func pageUpIsCSI5Tilde() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        surface.keyDown(with: try pageEvent(keyCode: 116, char: "\u{F72C}"))

        #expect(sent == Array("\u{1B}[5~".utf8), "PageUp must reach the child as CSI 5~")
    }

    @Test("PageDown (fn+↓) sends ESC[6~")
    func pageDownIsCSI6Tilde() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        surface.keyDown(with: try pageEvent(keyCode: 121, char: "\u{F72D}"))

        #expect(sent == Array("\u{1B}[6~".utf8), "PageDown must reach the child as CSI 6~")
    }
}
