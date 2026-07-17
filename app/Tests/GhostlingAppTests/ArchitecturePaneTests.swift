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

    /// The built SPA (hash history) serves views at `#/view/<id>/`; the bare `#/<id>`
    /// shape loads its 404 page — caught live in the task-99 dogfood capture.
    @Test func deepLinkUsesTheSPAsViewRoute() throws {
        let base = try #require(URL(string: "http://127.0.0.1:5500"))
        #expect(ArchitecturePane.deepLinkURL(base: base, view: "us-001-flow").absoluteString
            == "http://127.0.0.1:5500/#/view/us-001-flow/")
        #expect(ArchitecturePane.deepLinkURL(base: base, view: nil) == base)
    }

    /// With no `likec4` CLI and no cached build, the pane degrades exactly like mermaid:
    /// it shows the `.c4` source and an install hint — never blank, never a crash.
    @Test func degradesToSourceWhenNoCLIandNoBuild() throws {
        let pane = ArchitecturePane(cliPath: { nil })
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.present(projectDir: try projectWithModel(), deepLinkView: "task-01")
        if case .degraded = pane.lastContent {} else { Issue.record("expected .degraded") }
        pane.teardown()
    }

    @Test func failedRebuildKeepsLastGoodBuild() async throws {
        let project = try projectWithModel()
        let cacheBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("arch-pane-cache-\(UUID().uuidString)")
        let firstHash = try #require(LikeC4.hash(of: LikeC4.sources(projectDir: project)))
        let firstBuild = LikeC4.cacheDir(hash: firstHash, base: cacheBase)
        try FileManager.default.createDirectory(at: firstBuild, withIntermediateDirectories: true)
        try "<html>OLD</html>".write(to: firstBuild.appendingPathComponent("index.html"),
                                     atomically: true, encoding: .utf8)

        let pane = ArchitecturePane(cliPath: { "/bin/false" }, cacheBase: cacheBase)
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.present(projectDir: project, deepLinkView: "task-01")
        if case .ready = pane.lastContent {} else { Issue.record("expected cached build") }

        try "specification { element system }\nmodel { system edited }"
            .write(to: project.appendingPathComponent("docs/architecture/model.c4"),
                   atomically: true, encoding: .utf8)
        pane.present(projectDir: project, deepLinkView: "task-01")
        for _ in 0..<20 where pane.lastWarning == nil {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(pane.lastWarning == "Build failed — showing last good architecture build.")
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
