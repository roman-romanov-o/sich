import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// US-004 AC2 / TC-E2E-010: the Planning Mode terminal is a *normal*
/// `SessionRegistry`-registered interactive session — reused from the card's own pty,
/// never a new spawn and never `claude -p`. These drive the real production entry
/// (`createSession` → `enterPlanningMode`) rather than a bypass.
@MainActor
struct PlanningTerminalTests {

    @Test func planningTerminalIsTheCardsRegisteredSessionMountedOnce() throws {
        let folder = try fixture(readme: seed())
        let shell = BoardShell(seeds: [])
        shell.buildContentForTesting()
        defer { shell.e2eTeardown() }

        let card = try #require(shell.createSession(
            title: "planning", projectDir: folder.path, flow: .a, taskFolder: folder.path))
        shell.enterPlanningModeForTesting(card)

        // The pane hosts a live terminal (US-004 AC2: visible + registered).
        let surface = try #require(shell.planningMode.terminalSurface)
        #expect(surface.superview != nil)
        // It is the very session in the pool-firewalled registry — same path drill-in
        // uses, no second spawn.
        #expect(shell.isRegistered(surface.ptySession))
        #expect(shell.planningMode.cardID == card.id)
    }

    /// The pool firewall that guards every registry launch still rejects headless
    /// `claude -p` — the invariant the planning terminal must never weaken.
    @Test func poolFirewallStillForbidsHeadlessClaude() throws {
        #expect(throws: PoolViolation.self) {
            _ = try PoolFirewall.classify(["claude", "-p", "do the thing"])
        }
    }

    /// US-004 AC5 / TC-E2E-014: the ⌘[ "back to board" gesture — dispatched as a REAL
    /// key event through the window's responder chain (`performKeyEquivalent`), never by
    /// calling `returnToBoard()` — restores the board, releases the planning terminal's
    /// *view*, yet keeps the session registered. (Plain Esc deliberately flows to the
    /// child agent; only ⌘[ returns.)
    @Test func returningKeepsThePlanningSessionRegistered() throws {
        let folder = try fixture(readme: seed())
        let shell = BoardShell(seeds: [])
        let root = shell.buildContentForTesting()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { shell.e2eTeardown() }

        let card = try #require(shell.createSession(
            title: "planning", projectDir: folder.path, flow: .a, taskFolder: folder.path))
        shell.enterPlanningModeForTesting(card)
        root.layoutSubtreeIfNeeded()
        let surface = try #require(shell.planningMode.terminalSurface)
        let pty = surface.ptySession
        window.makeFirstResponder(surface)

        let cmdBracket = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33))
        let consumed = window.performKeyEquivalent(with: cmdBracket)

        #expect(consumed)                                    // ⌘[ was the back gesture
        #expect(shell.boardView.isHidden == false)           // board restored
        #expect(shell.planningMode.terminalSurface == nil)   // view released
        #expect(shell.isRegistered(pty))                     // session still alive
        #expect(shell.planningMode.isHidden)
    }

    private func seed() -> String {
        """
        | Research | Done |
        | Task Description | Done |
        | User Stories | Done |
        | Design Decisions | Pending |
        | Code Changes | Pending |
        """
    }

    private func fixture(readme content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try content.write(to: url.appendingPathComponent("README.md"), atomically: true,
                          encoding: .utf8)
        return url
    }
}
