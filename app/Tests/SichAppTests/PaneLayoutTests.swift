import AppKit
import Testing

@testable import SichApp

/// Hideable review rail + draggable pane boundaries (Planning Mode and drill-in).
/// Per the Interaction-AC Binding Rule every interaction here is exercised by
/// dispatching REAL `NSEvent`s (mouseDown/mouseDragged/mouseUp, ⌘J keyDown) at the
/// genuinely hit-tested view — never by calling `toggleRail()`-style handlers alone.
@MainActor
@Suite("Pane layout: rail fold + draggable dividers")
struct PaneLayoutTests {

    /// Scratch `UserDefaults` suite so a drag in a test never touches the
    /// operator's real persisted layout; removed again on the way out.
    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "sich-pane-layout-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// A real (offscreen) window so layout produces genuine pane bounds for the
    /// drag clamps, and hit-testing resolves against real geometry.
    private func mount(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func mouse(_ type: NSEvent.EventType, at location: NSPoint,
                       in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Real click: hit-test the target's center through the window's content view
    /// (proving it is reachable, not covered), then dispatch a left-mouse-down at it.
    private func click(_ target: NSView, in window: NSWindow) throws {
        let center = target.convert(
            NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let root = try #require(window.contentView)
        let hit = try #require(root.hitTest(center), "target must be hit-testable")
        #expect(hit === target, "the click point must resolve to the target itself")
        hit.mouseDown(with: try mouse(.leftMouseDown, at: center, in: window))
    }

    /// Real drag: mouseDown on the divider, mouseDragged by `deltaX` window points,
    /// mouseUp — the full gesture the operator performs.
    private func drag(_ divider: PaneDivider, by deltaX: CGFloat,
                      in window: NSWindow) throws {
        let center = divider.convert(
            NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        let root = try #require(window.contentView)
        let hit = try #require(root.hitTest(center), "divider must be hit-testable")
        #expect(hit === divider, "the grab strip itself must own the hit point")
        divider.mouseDown(with: try mouse(.leftMouseDown, at: center, in: window))
        divider.mouseDragged(with: try mouse(
            .leftMouseDragged, at: NSPoint(x: center.x + deltaX, y: center.y), in: window))
        divider.mouseUp(with: try mouse(
            .leftMouseUp, at: NSPoint(x: center.x + deltaX, y: center.y), in: window))
    }

    // MARK: - Store

    @Test("PaneLayoutStore round-trips widths and flags; unset keys yield defaults")
    func storeRoundTrip() throws {
        try withScratchDefaults { defaults in
            let store = PaneLayoutStore(defaults: defaults)
            #expect(store.width(forKey: "w", default: 386) == 386)
            store.setWidth(444, forKey: "w")
            #expect(store.width(forKey: "w", default: 386) == 444)
            #expect(store.bool(forKey: "b") == false)
            store.setBool(true, forKey: "b")
            #expect(store.bool(forKey: "b") == true)
        }
    }

    // MARK: - Planning Mode

    @Test("dragging the planning divider resizes the terminal, clamps, and persists")
    func planningDividerDragResizesAndPersists() throws {
        try withScratchDefaults { defaults in
            let view = PlanningModeView(paneLayout: PaneLayoutStore(defaults: defaults))
            let window = mount(view)

            // Collapsed terminal (the default) has no boundary to drag.
            #expect(view.paneDivider.isHidden == true)

            // Expand via a real click on the header chip, then drag left 100pt:
            // the terminal must grow by exactly that much.
            try click(view.terminalToggle, in: window)
            view.layoutSubtreeIfNeeded()
            #expect(view.paneDivider.isHidden == false)
            #expect(view.terminalPaneWidth == 386)
            try drag(view.paneDivider, by: -100, in: window)
            #expect(view.terminalPaneWidth == 486)
            #expect(defaults.double(forKey: PaneLayoutStore.planningTerminalWidthKey) == 486)

            // An absurd drag stops at the clamp: the reader keeps its 300pt minimum
            // (1280 window − 20 chrome insets − 7 divider − 270 rail − 300 reader).
            try drag(view.paneDivider, by: -10_000, in: window)
            #expect(view.terminalPaneWidth == 683)

            // Dragging right shrinks, floored at the terminal's own minimum.
            try drag(view.paneDivider, by: 10_000, in: window)
            #expect(view.terminalPaneWidth == 280)

            // A fresh view (same store) restores the persisted width.
            let restored = PlanningModeView(paneLayout: PaneLayoutStore(defaults: defaults))
            #expect(restored.terminalPaneWidth == 280)
        }
    }

    @Test("clicking the rail chip folds the review rail away and persists the choice")
    func planningRailToggleHidesAndPersists() throws {
        try withScratchDefaults { defaults in
            let view = PlanningModeView(paneLayout: PaneLayoutStore(defaults: defaults))
            let window = mount(view)
            #expect(view.isRailHidden == false)
            #expect(view.railToggle.stringValue == "◂ rail")

            try click(view.railToggle, in: window)
            #expect(view.isRailHidden == true)
            #expect(view.railToggle.stringValue == "rail ▸")
            #expect(defaults.bool(forKey: PaneLayoutStore.planningRailHiddenKey) == true)

            // A fresh view starts folded; clicking again brings the rail back.
            let restored = PlanningModeView(paneLayout: PaneLayoutStore(defaults: defaults))
            let restoredWindow = mount(restored)
            #expect(restored.isRailHidden == true)
            try click(restored.railToggle, in: restoredWindow)
            #expect(restored.isRailHidden == false)
            #expect(defaults.bool(forKey: PaneLayoutStore.planningRailHiddenKey) == false)
        }
    }

    @Test("⌘J toggles the planning terminal (real key-equivalent event)")
    func planningCmdJTogglesTerminal() throws {
        try withScratchDefaults { defaults in
            let view = PlanningModeView(paneLayout: PaneLayoutStore(defaults: defaults))
            let window = mount(view)
            _ = window
            let cmdJ = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "j",
                charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))

            #expect(view.paneDivider.isHidden == true, "starts collapsed")
            #expect(view.performKeyEquivalent(with: cmdJ) == true)
            #expect(view.paneDivider.isHidden == false, "⌘J expands the terminal")
            #expect(view.performKeyEquivalent(with: cmdJ) == true)
            #expect(view.paneDivider.isHidden == true, "⌘J collapses it again")
        }
    }

    // MARK: - Drill-in

    @Test("dragging the drill-in divider resizes the sidebar, clamps, and persists")
    func drillInDividerDragResizesAndPersists() throws {
        try withScratchDefaults { defaults in
            let panel = DrillInPanel(paneLayout: PaneLayoutStore(defaults: defaults))
            let window = mount(panel)
            #expect(panel.sidebarPaneWidth == 300)

            try drag(panel.paneDivider, by: -80, in: window)
            #expect(panel.sidebarPaneWidth == 380)
            #expect(defaults.double(forKey: PaneLayoutStore.drillInSidebarWidthKey) == 380)

            // Right past the floor: the sidebar keeps its 220pt minimum.
            try drag(panel.paneDivider, by: 10_000, in: window)
            #expect(panel.sidebarPaneWidth == 220)

            // Left past the ceiling: the terminal keeps its 400pt minimum
            // (1280 window − 7 divider − 400 terminal).
            try drag(panel.paneDivider, by: -10_000, in: window)
            #expect(panel.sidebarPaneWidth == 873)

            let restored = DrillInPanel(paneLayout: PaneLayoutStore(defaults: defaults))
            #expect(restored.sidebarPaneWidth == 873)
        }
    }
}
