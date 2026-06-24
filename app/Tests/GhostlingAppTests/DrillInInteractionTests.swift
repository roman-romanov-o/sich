import AppKit
import GhostlingCore
import Testing

@testable import GhostlingApp

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
            agent: .claude, flow: .a, state: .waitingForInput,
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
        #expect(shell.attention.isHidden == false)

        shell.drill(into: card)

        // The iter-1 defect was the board showing behind the terminal. The fix is
        // structural: board + attention hidden, terminal the only thing visible.
        #expect(shell.boardView.isHidden == true)
        #expect(shell.attention.isHidden == true)
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
        #expect(shell.attention.isHidden == false)
        #expect(shell.drillIn.isHidden == true)
        #expect(shell.cards.map(\.id) == before)   // nothing lost on the way back
    }

    /// The mouse path (US-002 AC#2). Drives a REAL `mouseDown` through the window's
    /// own event delivery, NOT a direct `goBack()` call — the Interaction-AC Binding
    /// Rule: a click AC must be exercised by a dispatched event. It also asserts the
    /// pill (not the embedded terminal that mounts over the panel) owns the click
    /// point — the geometry half of "I cannot see / cannot reach the pill". The
    /// pill's *visibility* remains a human sign-off; that it is reachable is here
    /// machine-verified.
    @Test("clicking the ← board pill returns to the board (real mouse-event path, US-002 AC#2)")
    func backPillClickReturnsToBoard() throws {
        let shell = BoardShell(seeds: singleSeed())
        let root = shell.buildContentForTesting()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = root

        let card = try #require(shell.cards.first)
        shell.drill(into: card)
        root.layoutSubtreeIfNeeded()

        // The pill's center, in window base coordinates.
        let pill = shell.drillIn.backPill
        let center = pill.convert(NSPoint(x: pill.bounds.midX, y: pill.bounds.midY), to: nil)

        // Geometry: real hit-testing resolves the point to the pill, NOT the terminal
        // surface mounted over the panel. RED if the surface (or anything) covers it —
        // the class of bug behind "the pill isn't there / can't be reached".
        let hit = try #require(root.hitTest(center))
        #expect(hit === pill,
            "the ← board pill must be the hit target, not covered by the terminal")

        // Act: a real left-mouse-down, dispatched to the genuinely hit-tested view.
        // (Like the Esc test, this dispatches to the resolved target directly rather
        // than through `NSWindow.sendEvent`, whose mouse routing is gated for an
        // offscreen, non-key window — that gating is AppKit's behavior, not ours.)
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        hit.mouseDown(with: click)

        // Assert: the click returned to the board.
        #expect(shell.drillIn.isHidden == true,
            "clicking ← board must return to the board")
        #expect(shell.boardView.isHidden == false)
        #expect(shell.attention.isHidden == false)
    }

    /// The test the previous two iterations were missing. A handler-call test (the
    /// old `backAffordanceFiresReturn`, which called `goBack()` *directly*) proves
    /// the handler works, never that pressing Esc reaches it. That gap shipped a
    /// drill-in where Esc typed an escape symbol into the terminal instead of
    /// returning, three times, all green. (The click path is likewise driven by a
    /// real event now — see `backPillClickReturnsToBoard`.)
    ///
    /// This drives the REAL input path: a real `Esc` `NSEvent` (keyCode 53)
    /// delivered to the actual first responder after a real drill-in. It is RED
    /// while `TerminalSurface` forwards Esc to the PTY, and only goes GREEN once
    /// the surface offers Esc to its host. The one sliver it does not cover is
    /// `NSWindow.sendEvent`'s own decision to route a keyDown to the first
    /// responder (AppKit's behavior, not ours) — so it dispatches to
    /// `window.firstResponder` directly, which is deterministic headlessly.
    @Test("pressing Esc in the drilled-in terminal returns to the board (real key-event path, US-002 AC#2)")
    func escReturnsToBoardViaEventDispatch() throws {
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
        // fails, the drill-in wiring itself is broken (a class of bug the old test
        // could not see either).
        let responder = try #require(window.firstResponder as? TerminalSurface)

        // Act: a real Esc keypress, delivered the way AppKit delivers one — NOT a
        // direct goBack() call.
        let esc = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        responder.keyDown(with: esc)

        // Assert: Esc returned to the board. RED today (the terminal sends Esc to the
        // PTY, board stays hidden); GREEN once the surface routes Esc back.
        #expect(shell.drillIn.isHidden == true,
            "Esc must return to the board, not type an escape symbol into the terminal")
        #expect(shell.boardView.isHidden == false)
        #expect(shell.attention.isHidden == false)
    }
}
