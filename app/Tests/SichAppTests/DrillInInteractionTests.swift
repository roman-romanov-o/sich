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

    /// Fabricate a linked git worktree (a `.git` FILE pointing at the main repo's
    /// `worktrees/<name>` metadata) and return the checkout path. Pure filesystem —
    /// no real `git`, so it never mints a worktree in this repo.
    private func makeWorktreeCheckout(branch: String) throws -> String {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
        let meta = base.appendingPathComponent("main/.git/worktrees/wt")
        let checkout = base.appendingPathComponent("wt")
        try fm.createDirectory(at: meta, withIntermediateDirectories: true)
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n".write(
            to: meta.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(
            to: meta.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(meta.path)\n".write(
            to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return checkout.path
    }

    /// Drilling into a card that lives in a git worktree surfaces the amber worktree
    /// pill with the branch name, so the operator sees edits land on a side branch.
    /// A normal checkout leaves it hidden — the indicator is opt-in on real geometry.
    @Test("drill-in shows the worktree indicator for a worktree checkout, hides it otherwise")
    func worktreeIndicatorReflectsCheckout() throws {
        let checkout = try makeWorktreeCheckout(branch: "task/fix-login")
        let seeds = [
            BoardSeed(sessionID: "wt/one", projectDir: checkout,
                      agent: .claude, state: .running, scrollback: "on a worktree"),
            BoardSeed(sessionID: "plain/one", projectDir: "/tmp",
                      agent: .claude, state: .running, scrollback: "shared checkout"),
        ]
        let shell = BoardShell(seeds: seeds)
        shell.buildContentForTesting()
        let worktreeCard = try #require(shell.cards.first { $0.projectDir == checkout })
        let plainCard = try #require(shell.cards.first { $0.projectDir == "/tmp" })

        shell.drill(into: worktreeCard)
        #expect(shell.drillIn.worktreeTag.isHidden == false,
            "a worktree checkout shows the indicator")
        #expect(shell.drillIn.worktreeTag.stringValue == "WORKTREE · task/fix-login",
            "the pill names the worktree branch")

        // A plain (non-worktree) card leaves the pill hidden.
        shell.returnToBoard()
        shell.drill(into: plainCard)
        #expect(shell.drillIn.worktreeTag.isHidden == true,
            "a normal checkout hides the indicator")
    }
}
