import AppKit
import Testing

@testable import SichApp

/// Draggable pane boundary + its persisted layout store.
/// Per the Interaction-AC Binding Rule every interaction here is exercised by
/// dispatching REAL `NSEvent`s (mouseDown/mouseDragged/mouseUp) at the genuinely
/// hit-tested view — never by calling handlers alone.
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

}
