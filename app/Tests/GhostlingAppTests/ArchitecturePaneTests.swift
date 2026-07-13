import AppKit
import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

@MainActor
struct ArchitecturePaneTests {
    private func projectWithModel() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arch-pane-\(UUID().uuidString)")
        let arch = root.appendingPathComponent("docs/architecture")
        try FileManager.default.createDirectory(at: arch, withIntermediateDirectories: true)
        try "specification { element system }\nmodel { system kanban }"
            .write(to: arch.appendingPathComponent("model.c4"), atomically: true, encoding: .utf8)
        return root
    }

    /// With no `likec4` CLI and no cached build, the pane degrades exactly like mermaid:
    /// it shows the `.c4` source and an install hint — never blank, never a crash.
    @Test func degradesToSourceWhenNoCLIandNoBuild() throws {
        try #require(LikeC4.cliPath() == nil, "test asserts the degrade path; skip if likec4 is installed")
        let pane = ArchitecturePane()
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.present(projectDir: try projectWithModel(), deepLinkView: "task-01")
        if case .degraded = pane.lastContent {} else { Issue.record("expected .degraded") }
        pane.teardown()
    }

    /// Clicking the header "Architecture" toggle with a REAL mouseDown reveals the pane
    /// (interaction-AC binding rule — never `performClick`), and clicking it off hides it.
    @Test func toggleRevealsAndHidesPaneViaRealClick() throws {
        let view = PlanningModeView(reader: PlanningStateReader())
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()

        #expect(view.architecturePane.isHidden)
        let pill = view.architectureToggle
        let center = pill.convert(NSPoint(x: pill.bounds.midX, y: pill.bounds.midY), to: nil)
        let hit = try #require(view.hitTest(center))
        #expect(hit === pill)
        func click() throws {
            let e = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(e)
        }
        try click()
        #expect(!view.architecturePane.isHidden)
        try click()
        #expect(view.architecturePane.isHidden)
    }
}
