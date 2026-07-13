import AppKit
import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// US-004 AC3/AC4 + edge case 1 (TC-E2E-012 / 012b / 013): the suggest-only step
/// interaction. Every assertion here is driven by a REAL dispatched `NSEvent`
/// (`mouseDown` for the step, `keyDown` for typing) — never a direct handler or
/// `performClick` call. This repo has shipped three green-but-broken interaction ACs
/// exactly by taking that shortcut (see interaction-AC-binding-rule memory).
@MainActor
struct PlanningStepInteractionTests {

    /// TC-E2E-012 — clicking the next-incomplete step pre-types its command (unsent,
    /// no newline) AND selects its doc.
    @Test func clickingNextIncompletePreTypesCommandAndSelectsDoc() throws {
        let ctx = try planning()
        defer { ctx.shell.e2eTeardown() }

        try ctx.click(.designDecisions)

        let surface = try #require(ctx.shell.planningMode.terminalSurface)
        #expect(surface.unsentInput == "/saha:decide")     // typed, not submitted
        #expect(!surface.unsentInput.contains("\n"))        // no Enter was sent
        #expect(ctx.shell.planningMode.selectedStep == .designDecisions)
    }

    /// TC-E2E-012b — clicking an already-done step selects its doc but types nothing.
    @Test func clickingDoneStepSelectsDocWithoutTyping() throws {
        let ctx = try planning()
        defer { ctx.shell.e2eTeardown() }

        try ctx.click(.taskDescription)

        let surface = try #require(ctx.shell.planningMode.terminalSurface)
        #expect(ctx.shell.planningMode.selectedStep == .taskDescription)
        #expect(surface.unsentInput.isEmpty)               // done step: doc only
    }

    /// TC-E2E-013 — clicking a step while the terminal already has unsent input is a
    /// no-op that preserves every byte and surfaces visible feedback.
    @Test func clickWithUnsentInputIsNoOpWithFeedback() throws {
        let ctx = try planning()
        defer { ctx.shell.e2eTeardown() }
        let surface = try #require(ctx.shell.planningMode.terminalSurface)

        ctx.type("abc", into: surface)
        #expect(surface.unsentInput == "abc")

        try ctx.click(.designDecisions)

        #expect(surface.unsentInput == "abc")              // nothing appended/overwritten
        #expect(ctx.shell.planningMode.lastFeedback != nil)
        #expect(!ctx.shell.planningMode.feedbackField.stringValue.isEmpty)
    }

    // MARK: - Harness

    @MainActor
    private struct Ctx {
        let shell: BoardShell
        let root: NSView
        let window: NSWindow

        func button(_ step: PlanningStep) throws -> PlanningStepButton {
            try #require(shell.planningMode.stepperPane.arrangedSubviews
                .compactMap { $0 as? PlanningStepButton }.first { $0.step == step })
        }

        /// Dispatch a genuine left-click on a step row through real window hit-testing.
        func click(_ step: PlanningStep) throws {
            root.layoutSubtreeIfNeeded()
            let b = try button(step)
            let center = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
            let hit = try #require(root.hitTest(center))
            #expect(hit === b, "the step row must own the click point, not a pane behind it")
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }

        /// Dispatch real `keyDown` events for each character through the window to the
        /// first-responder terminal surface (real responder chain, not a direct call).
        func type(_ text: String, into surface: TerminalSurface) {
            window.makeFirstResponder(surface)
            for ch in text {
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    characters: String(ch), charactersIgnoringModifiers: String(ch),
                    isARepeat: false, keyCode: 0)
                if let event { window.sendEvent(event) }
            }
        }
    }

    /// TC-E2E-010 state: first three steps Done, Design Decisions the next incomplete.
    private func planning() throws -> Ctx {
        let folder = try fixture(readme: """
        | Research | Done |
        | Task Description | Done |
        | User Stories | Done |
        | Design Decisions | Pending |
        | Code Changes | Pending |
        """)
        let shell = BoardShell(seeds: [])
        let root = shell.buildContentForTesting()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        let card = try #require(shell.createSession(
            title: "planning", projectDir: folder.path, flow: .a, taskFolder: folder.path))
        shell.enterPlanningModeForTesting(card)
        root.layoutSubtreeIfNeeded()
        return Ctx(shell: shell, root: root, window: window)
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
