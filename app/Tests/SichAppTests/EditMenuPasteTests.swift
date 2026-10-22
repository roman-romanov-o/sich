import AppKit
import Testing

@testable import SichApp

/// ⌘V was dead in every text field the app owns — the create palette's host field
/// among them — because the hand-built main menu had no Edit submenu, and AppKit
/// routes ⌘X/⌘C/⌘V/⌘A to the focused field editor ONLY through a menu key equivalent.
///
/// The path has two halves, and these tests assert each with a real AppKit dispatch:
///
///   1. main menu claims the chord — `NSMenu.performKeyEquivalent(with:)` on a REAL
///      ⌘V `NSEvent`. This is the half that was broken, and it has a red/green pair:
///      with the Edit menu it returns true, with the app's old bare menu it returns
///      false. No handler is called anywhere.
///   2. the claimed item resolves against the first responder — the item is nil-targeted
///      with action `paste:`, and the responder chain answers it (`tryToPerform`, the
///      same walk AppKit performs, on the `NSTextView` a focused `NSTextField` installs
///      as its field editor).
///
/// The two are asserted separately on purpose: joining them needs a KEY window, and a
/// test bundle has no activation policy — `NSApp.target(forAction: paste:)` is nil until
/// the app is frontmost, and activating it would steal the user's focus on every run.
///
/// Nothing here touches `NSPasteboard.general`: proving ROUTING needs no clipboard
/// content, so a test run can't clobber the real pasteboard — the same reason
/// `TerminalSurface` takes an injected pasteboard.
@MainActor
@Suite("Edit menu restores ⌘V routing to text fields", .serialized)
struct EditMenuPasteTests {

    /// Records the responder-chain action instead of performing it. An `NSTextView` is
    /// exactly what a focused `NSTextField` installs as its field editor.
    private final class PasteSpy: NSTextView {
        var pastes = 0
        override func paste(_ sender: Any?) { pastes += 1 }
    }

    /// `NSApplication.shared`, not `NSApp`: the global is a nil implicitly-unwrapped
    /// optional until the shared instance is first created, which under `--filter`
    /// nothing else in the suite has done yet.
    private func withMainMenu(_ menu: NSMenu, _ body: () throws -> Void) rethrows {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }
        app.mainMenu = menu
        try body()
    }

    private func cmdV() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ))
    }

    @Test("the main menu claims ⌘V when the V key types a Cyrillic glyph")
    func mainMenuClaimsCmdVOnNonLatinLayout() throws {
        let menu = LayoutAwareMenu()
        menu.addItem(EditMenu.item())
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "м", charactersIgnoringModifiers: "м",
            isARepeat: false, keyCode: 9
        ))
        try withMainMenu(menu) {
            #expect(menu.performKeyEquivalent(with: event),
                "⌘V in a text field must survive a Ukrainian layout")
        }
    }

    /// Claiming the chord is not enough — the Paste item has to run, once.
    @Test("a Cyrillic ⌘V performs Paste exactly once")
    func cyrillicCmdVPerformsPasteOnce() throws {
        let spy = PasteSpy(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let menu = LayoutAwareMenu(title: "Edit")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)),
                               keyEquivalent: "v")
        paste.target = spy
        menu.addItem(paste)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "м", charactersIgnoringModifiers: "м",
            isARepeat: false, keyCode: 9
        ))
        #expect(menu.performKeyEquivalent(with: event))
        #expect(spy.pastes == 1)
    }

    @Test("the main menu claims ⌘V once the Edit menu is installed")
    func mainMenuClaimsCmdV() throws {
        let menu = NSMenu()
        menu.addItem(EditMenu.item())
        let event = try cmdV()
        try withMainMenu(menu) {
            #expect(menu.performKeyEquivalent(with: event),
                "the Edit menu must claim ⌘V — this is the half that was missing")
        }
    }

    /// The mutation that reproduces the shipped bug: the app's menu before the fix —
    /// an app item and nothing else — has no ⌘V key equivalent anywhere, so a focused
    /// text field is never asked to paste.
    @Test("without the Edit menu ⌘V is claimed by nothing — the bug this fixes")
    func cmdVIsDeadWithoutTheEditMenu() throws {
        let bare = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Sich")
        bare.addItem(appItem)
        let event = try cmdV()
        try withMainMenu(bare) {
            #expect(bare.performKeyEquivalent(with: event) == false)
        }
    }

    /// Half two: the ⌘V item carries `paste:` with NO target, so AppKit sends it down
    /// the responder chain — and a field editor answers it.
    @Test("the ⌘V item is nil-targeted and the field editor answers paste:")
    func pasteItemResolvesAgainstTheFirstResponder() throws {
        let submenu = try #require(EditMenu.item().submenu)
        let paste = try #require(submenu.items.first { $0.keyEquivalent == "v" })
        #expect(paste.action == #selector(NSText.paste(_:)))
        #expect(paste.target == nil, "a fixed target would skip the focused field")

        let spy = PasteSpy(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        #expect(spy.tryToPerform(try #require(paste.action), with: nil))
        #expect(spy.pastes == 1)
    }

    @Test("the Edit menu carries the standard editing chords")
    func editMenuCarriesTheStandardChords() throws {
        let submenu = try #require(EditMenu.item().submenu)
        let chords = submenu.items
            .filter { !$0.isSeparatorItem }
            .map { ($0.keyEquivalent, $0.keyEquivalentModifierMask.contains(.command)) }
        #expect(chords.allSatisfy { $0.1 }, "every editing chord is ⌘-based")
        #expect(Set(chords.map(\.0)) == ["z", "x", "c", "v", "a"])
    }

    /// The terminal owns ⌘V for bracketed paste; a window's view hierarchy is offered
    /// key equivalents BEFORE the main menu, so adding the Edit menu must not have
    /// moved that boundary.
    @Test("the Edit menu does not outrank a view that claims ⌘V itself")
    func viewHierarchyStillWinsOverTheMenu() throws {
        final class Claimer: NSView {
            var claims = 0
            override func performKeyEquivalent(with event: NSEvent) -> Bool {
                claims += 1
                return true
            }
        }
        let menu = NSMenu()
        menu.addItem(EditMenu.item())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let claimer = Claimer(frame: window.contentLayoutRect)
        window.contentView?.addSubview(claimer)
        // orderOut, not close(): a programmatically created NSWindow defaults to
        // isReleasedWhenClosed, which over-releases under ARC and segfaults the runner.
        defer { window.orderOut(nil) }

        let event = try cmdV()
        try withMainMenu(menu) {
            #expect(window.performKeyEquivalent(with: event),
                "the view hierarchy answers first, so TerminalSurface keeps its own ⌘V")
            #expect(claimer.claims == 1)
        }
    }
}
