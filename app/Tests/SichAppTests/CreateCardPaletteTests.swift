import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// The ⌘N create palette (project → harness → task), driven by REAL dispatched
/// `NSEvent`s — key events through `NSWindow.sendEvent` for stage navigation and a
/// genuine `leftMouseDown` for row activation. Never `performClick`/direct handler
/// calls: this is the interaction-AC-binding-rule the repo has shipped broken before.
@MainActor
private func makePalette(recents: [PaletteProject]) -> (CreateCardPalette, NSView, NSWindow) {
    let palette = CreateCardPalette(recents: recents)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
    palette.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(palette)
    NSLayoutConstraint.activate([
        palette.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        palette.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        palette.topAnchor.constraint(equalTo: root.topAnchor),
        palette.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    let window = NSWindow(
        contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = root
    window.makeKeyAndOrderFront(nil)
    palette.focusStage()          // exactly what the shell's mount does
    root.layoutSubtreeIfNeeded()
    return (palette, root, window)
}

/// Dispatch a real key press to the window's first responder (the palette, or its
/// name-field editor on the task stage) — the same delivery path a physical key uses.
@MainActor
private func pressKey(_ keyCode: UInt16, chars: String = "", in window: NSWindow) {
    let down = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: keyCode)!
    window.sendEvent(down)
}

/// A genuine left-click on a palette row through real hit-testing + the window's own
/// event delivery — the binding-rule-compliant "real gesture" for row activation.
@MainActor
private func clickRow(_ view: NSView, root: NSView, window: NSWindow) throws {
    root.layoutSubtreeIfNeeded()
    let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    let hit = try #require(root.hitTest(center))
    #expect(hit === view, "the row must own its own click point")
    let event = try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
    window.sendEvent(event)
}

private let kReturn: UInt16 = 36

// MARK: - Tests

/// The task stage: a real Return fires `confirmInteractive` with the chosen harness + dir.
@MainActor
@Test func interactivePathReachesConfirmViaRealEvents() throws {
    let proj = URL(fileURLWithPath: "/tmp/demo-project", isDirectory: true)
    let (palette, _, window) = makePalette(
        recents: [PaletteProject(path: proj.path, activeCards: 0)])

    var captured: (title: String, dir: String, harness: CreateCardPalette.Harness, inWorktree: Bool)?
    palette.confirmInteractive = { title, dir, harness, inWorktree, _ in
        captured = (title, dir, harness, inWorktree)
    }

    pressKey(kReturn, chars: "\r", in: window)     // "This Mac"
    pressKey(kReturn, chars: "\r", in: window)     // project
    pressKey(kReturn, chars: "\r", in: window)     // harness (Claude Code) → account
    pressKey(kReturn, chars: "\r", in: window)     // default account → task
    #expect(palette.stage == .task)

    #expect(palette.navRows.isEmpty, "the task stage is a name field, not a list")
    #expect(palette.worktreeToggleForTesting != nil, "the task stage shows the worktree option")

    palette.nameField.stringValue = "poke around"
    pressKey(kReturn, chars: "\r", in: window)     // Return in the field editor confirms

    let got = try #require(captured)
    #expect(got.title == "poke around")
    #expect(got.dir == proj.path)
    #expect(got.harness == .claude, "Claude Code harness was chosen at stage 2")
    #expect(!got.inWorktree, "own-worktree is OFF by default — a worktree is an opt-in")
}

/// Cursor sits after Codex in the harness list and carries through the same way.
@MainActor
@Test func cursorHarnessReachesInteractiveConfirmViaRealEvents() throws {
    let proj = URL(fileURLWithPath: "/tmp/demo-project", isDirectory: true)
    let (palette, _, window) = makePalette(
        recents: [PaletteProject(path: proj.path, activeCards: 0)])

    var captured: CreateCardPalette.Harness?
    palette.confirmInteractive = { _, _, harness, _, _ in captured = harness }

    pressKey(kReturn, chars: "\r", in: window)     // "This Mac"
    pressKey(kReturn, chars: "\r", in: window)     // project
    pressKey(125, in: window)                      // Claude → Codex
    pressKey(125, in: window)                      // Codex → Cursor
    pressKey(kReturn, chars: "\r", in: window)     // Cursor → account
    #expect(palette.stage == .agentAccount)
    pressKey(kReturn, chars: "\r", in: window)     // default account → task
    #expect(palette.stage == .task)
    palette.nameField.stringValue = "try cursor"
    pressKey(kReturn, chars: "\r", in: window)

    #expect(captured == .cursor)
    #expect(captured?.cardAgent == .cursor)
}

/// Antigravity sits after Cursor in the harness list.
@MainActor
@Test func antigravityHarnessReachesInteractiveConfirmViaRealEvents() throws {
    let proj = URL(fileURLWithPath: "/tmp/demo-project", isDirectory: true)
    let (palette, _, window) = makePalette(
        recents: [PaletteProject(path: proj.path, activeCards: 0)])

    var captured: CreateCardPalette.Harness?
    palette.confirmInteractive = { _, _, harness, _, _ in captured = harness }

    pressKey(kReturn, chars: "\r", in: window)     // "This Mac"
    pressKey(kReturn, chars: "\r", in: window)     // project
    pressKey(125, in: window)                      // Claude → Codex
    pressKey(125, in: window)                      // Codex → Cursor
    pressKey(125, in: window)                      // Cursor → Antigravity
    pressKey(kReturn, chars: "\r", in: window)     // Antigravity → task
    #expect(palette.stage == .task)
    palette.nameField.stringValue = "try agy"
    pressKey(kReturn, chars: "\r", in: window)

    #expect(captured == .antigravity)
    #expect(captured?.cardAgent == .antigravity)
}

/// Codex path: selecting Codex at the harness stage carries through the interactive
/// task confirmation, instead of collapsing into the old Claude/bare-shell Boolean.
@MainActor
@Test func codexHarnessReachesInteractiveConfirmViaRealEvents() throws {
    let proj = URL(fileURLWithPath: "/tmp/demo-project", isDirectory: true)
    let (palette, _, window) = makePalette(
        recents: [PaletteProject(path: proj.path, activeCards: 0)])

    var captured: CreateCardPalette.Harness?
    palette.confirmInteractive = { _, _, harness, _, _ in captured = harness }

    pressKey(kReturn, chars: "\r", in: window)     // "This Mac"
    pressKey(kReturn, chars: "\r", in: window)     // project
    pressKey(125, in: window)                      // harness: Claude → Codex
    pressKey(kReturn, chars: "\r", in: window)     // Codex → account
    #expect(palette.stage == .agentAccount)
    pressKey(kReturn, chars: "\r", in: window)     // default account → task
    #expect(palette.stage == .task)

    #expect(palette.navRows.isEmpty, "interactive terminal remains the default for Codex")
    palette.nameField.stringValue = "try codex"
    pressKey(kReturn, chars: "\r", in: window)

    #expect(captured == .codex)
}

/// Toggling the worktree switch on carries through to the confirm — the opt-IN for
/// "give this task its own isolated checkout". Driven by a real dispatched click on
/// the custom toggle (the interaction-AC binding rule), not a `performClick`/state poke.
@MainActor
@Test func worktreeToggleOptInReachesConfirm() throws {
    let proj = URL(fileURLWithPath: "/tmp/demo-project", isDirectory: true)
    let (palette, root, window) = makePalette(
        recents: [PaletteProject(path: proj.path, activeCards: 0)])
    var captured: Bool?
    palette.confirmInteractive = { _, _, _, inWorktree, _ in captured = inWorktree }

    pressKey(kReturn, chars: "\r", in: window)     // "This Mac"
    pressKey(kReturn, chars: "\r", in: window)     // project
    pressKey(kReturn, chars: "\r", in: window)     // harness → account
    pressKey(kReturn, chars: "\r", in: window)     // default account → task

    let toggle = try #require(palette.worktreeToggleForTesting, "interactive stage shows the worktree toggle")
    #expect(!toggle.isOn, "the toggle starts off")
    try clickRow(toggle, root: root, window: window)   // a genuine leftMouseDown flips it on
    #expect(toggle.isOn, "clicking the toggle turns it on")
    palette.nameField.stringValue = "isolated checkout task"
    pressKey(kReturn, chars: "\r", in: window)

    #expect(captured == true, "toggled-on worktree reaches confirmInteractive")
}

/// Esc at the first stage cancels — a real key event reaches `onCancel`.
@MainActor
@Test func escapeAtFirstStageCancels() throws {
    let (palette, _, window) = makePalette(
        recents: [PaletteProject(path: "/tmp/demo-project", activeCards: 0)])
    var cancelled = false
    palette.onCancel = { cancelled = true }
    pressKey(53, chars: "\u{1b}", in: window)   // esc, carrying the character a real key sends
    #expect(cancelled)
}
