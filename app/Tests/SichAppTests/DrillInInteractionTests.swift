import AppKit
import SichCore
import Testing

@testable import SichApp

/// View-level drill-in tests (US-002). These exist because the iter-2 visual
/// sign-off found the drill-in broken (a black, unreachable terminal) while the
/// suite was green: the only "return to board" coverage was
/// `BoardSelectionTests.focusAndReturn`, which exercises the `BoardSelection`
/// value type and never touches `BoardShell`, `DrillInPanel`, or the view
/// hierarchy. These drive the real views, so the wiring — board hidden on drill,
/// restored on return, and a back affordance that actually fires — is machine-
/// verified, not left to a human glance.
@MainActor
@Suite("Drill-in interaction wiring (US-002 — view layer)")
struct DrillInInteractionTests {

    /// One firewall-clean demo seed → one `cat` stub. Internal init reachable via
    /// `@testable`, so we spawn a single child instead of the full demo spread.
    private func singleSeed() -> [BoardSeed] {
        [BoardSeed(
            sessionID: "demo/one", projectDir: "~/demo",
            agent: .claude, state: .waitingForInput,
            scrollback: "waiting on you"
        )]
    }

    @Test("drilling into a card hides the board + attention (full-window takeover)")
    func drillHidesBoard() throws {
        let shell = BoardShell(seeds: singleSeed())
        shell.buildContentForTesting()
        let card = try #require(shell.cards.first)

        // Starts on the board.
        #expect(shell.drillIn.isHidden == true)
        #expect(shell.boardView.isHidden == false)

        shell.drill(into: card)

        // The iter-1 defect was the board showing behind the terminal. The fix is
        // structural: board + attention hidden, terminal the only thing visible.
        #expect(shell.boardView.isHidden == true)
        #expect(shell.drillIn.isHidden == false)
    }

    @Test("returning to the board restores it with the same cards (US-002 AC#2)")
    func returnRestoresBoard() throws {
        let shell = BoardShell(seeds: singleSeed())
        shell.buildContentForTesting()
        let card = try #require(shell.cards.first)
        let before = shell.cards.map(\.id)

        shell.drill(into: card)
        shell.returnToBoard()

        #expect(shell.boardView.isHidden == false)
        #expect(shell.drillIn.isHidden == true)
        #expect(shell.cards.map(\.id) == before)   // nothing lost on the way back
    }

    /// A real window with the production titlebar on it — the toolbar lives on the
    /// window, not in the content view, so the titlebar tests need both.
    private func drilledWindow(_ shell: BoardShell) -> NSWindow {
        let root = shell.buildContentForTesting()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.contentView = root
        shell.titlebar.install(on: window)
        root.layoutSubtreeIfNeeded()
        return window
    }

    /// The mouse path (US-002 AC#2): the titlebar's "‹ Board" button, clicked through
    /// the control's own action path (`performClick`), not a direct `goBack()` call.
    @Test("clicking ‹ Board in the titlebar returns to the board (US-002 AC#2)")
    func titlebarBackReturnsToBoard() throws {
        let shell = BoardShell(seeds: singleSeed())
        _ = drilledWindow(shell)
        let card = try #require(shell.cards.first)
        shell.drill(into: card)
        #expect(shell.titlebar.isShowing, "an open card shows the titlebar")

        shell.titlebar.backButton.performClick(nil)

        #expect(shell.drillIn.isHidden == true, "‹ Board must return to the board")
        #expect(shell.boardView.isHidden == false)
        #expect(!shell.titlebar.isShowing, "the board keeps its plain titlebar")
    }

    /// The point of the redesign: after switching, the first thing you read is which
    /// task you are in — its title and where it runs, in the window's own titlebar.
    @Test("drilling in names the task and its folder in the titlebar; back restores the board's")
    func titlebarNamesTheTask() throws {
        let shell = BoardShell(seeds: [BoardSeed(
            sessionID: "demo/one", projectDir: NSHomeDirectory() + "/demo",
            agent: .claude, state: .running, scrollback: "ready")])
        let window = drilledWindow(shell)
        window.title = "Sich — mission control"
        window.backgroundColor = BoardTheme.canvas
        let card = try #require(shell.cards.first)
        let frame = window.frame

        shell.drill(into: card)
        let title = card.title ?? BoardTheme.shortPath(card.projectDir)
        #expect(shell.titlebar.plate.titleForTesting == title)
        #expect(shell.titlebar.plate.directoryForTesting == "~/demo")
        #expect(window.title == title, "the Window menu and VoiceOver read the task too")
        #expect(window.backgroundColor == BoardTheme.termBg, "titlebar and terminal share one paper")
        #expect(window.frame == frame, "showing the toolbar must not resize the window")

        shell.returnToBoard()
        #expect(window.title == "Sich — mission control")
        #expect(window.backgroundColor == BoardTheme.canvas)
        #expect(window.frame == frame, "hiding it must not either")
    }

    @Test("a remote card's folder reads host:path")
    func remoteDirectoryReadsHostPath() {
        let card = BoardCard(sessionID: "remote/roman@studio.tail00ee33.ts.net/api", projectDir: "roman@studio.tail00ee33.ts.net",
                             agent: .claude, state: .idle, remoteDir: "~/work/api")
        #expect(TaskTitlebar.directory(of: card) == "roman@studio:~/work/api")
    }

    /// The keyboard path back (US-002 AC#2), driven by a REAL `⌘[` `NSEvent` through
    /// the key-equivalent route — not a direct `goBack()` call. `⌘[` is the back
    /// shortcut (the macOS "Back" idiom) precisely because plain `Esc` belongs to the
    /// child agent; see `escFlowsToChildNotBoard`. Dispatched to the resolved first
    /// responder directly, which is deterministic headlessly (AppKit's own window-level
    /// routing is gated for an offscreen, non-key window — that gating is not ours).
    @Test("pressing ⌘[ in the drilled-in terminal returns to the board (real key-event path, US-002 AC#2)")
    func cmdBracketReturnsToBoardViaEventDispatch() throws {
        let shell = BoardShell(seeds: singleSeed())
        let root = shell.buildContentForTesting()

        // A real (offscreen) window, so there is a genuine responder chain to
        // dispatch into — not a detached view with no window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = root
        root.layoutSubtreeIfNeeded()

        let card = try #require(shell.cards.first)
        shell.drill(into: card)

        // Precondition: drilling in actually focuses the embedded terminal. If this
        // fails, the drill-in wiring itself is broken.
        let responder = try #require(window.firstResponder as? TerminalSurface)

        // Act: a real ⌘[ keypress via the key-equivalent path — NOT a direct goBack().
        let cmdBracket = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "[", charactersIgnoringModifiers: "[",
            isARepeat: false, keyCode: 33
        ))
        #expect(responder.performKeyEquivalent(with: cmdBracket) == true,
            "the surface must claim ⌘[ as the back shortcut")

        // Assert: ⌘[ returned to the board.
        #expect(shell.drillIn.isHidden == true,
            "⌘[ must return to the board")
        #expect(shell.boardView.isHidden == false)
    }

    /// The reason the shortcut moved off Esc: a drilled-in interactive agent (Claude
    /// Code's `Esc` interrupt / `Esc Esc` edit) needs Esc to reach the child, so plain
    /// Esc must NOT bounce back to the board. RED if Esc is ever re-bound to back.
    @Test("plain Esc flows to the child, it does NOT return to the board")
    func escFlowsToChildNotBoard() throws {
        let shell = BoardShell(seeds: singleSeed())
        let root = shell.buildContentForTesting()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = root
        root.layoutSubtreeIfNeeded()

        let card = try #require(shell.cards.first)
        shell.drill(into: card)
        let responder = try #require(window.firstResponder as? TerminalSurface)

        let esc = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        responder.keyDown(with: esc)

        // Still drilled in: Esc went to the PTY, not to goBack().
        #expect(shell.drillIn.isHidden == false,
            "Esc must reach the child agent, not return to the board")
        #expect(shell.boardView.isHidden == true)
    }
}
