import AppKit
import SichCore
import Testing

@testable import SichApp

/// "Minimize the DONE section to save some space": folded, DONE is a narrow rail
/// and its width goes to the three live columns. The choice survives a relaunch.
@MainActor
@Suite("DONE column folds into a rail")
struct DoneRailTests {
    private func freshBoard(defaults: UserDefaults = .scratch) -> BoardView {
        let view = BoardView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), defaults: defaults)
        view.render(cards: [
            BoardCard(sessionID: "w", title: "working", projectDir: "/p", agent: .claude,
                      flow: .b, state: .running),
            BoardCard(sessionID: "d", title: "finished", projectDir: "/p", agent: .claude,
                      flow: .b, state: .done)
        ])
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func first<T: NSView>(_ type: T.Type, in view: NSView, identifier: String) -> T? {
        if let match = view as? T, match.identifier?.rawValue == identifier { return match }
        for sub in view.subviews {
            if let found = first(type, in: sub, identifier: identifier) { return found }
        }
        return nil
    }

    private func workingWidth(_ view: BoardView) throws -> CGFloat {
        let cell = try #require(view.cellForTesting(.working))
        return try #require(cell.enclosingScrollView).frame.width
    }

    @Test("the fold toggle shrinks DONE to a rail and widens the live columns")
    func toggleFoldsDoneIntoRail() throws {
        let view = freshBoard()
        #expect(!view.isDoneCollapsed)
        let expandedWorking = try workingWidth(view)

        let toggle = try #require(first(NSButton.self, in: view, identifier: "done-collapse-toggle"))
        toggle.performClick(nil)
        view.layoutSubtreeIfNeeded()

        #expect(view.isDoneCollapsed)
        let rail = try #require(first(NSView.self, in: view, identifier: "done-rail"))
        #expect(rail.frame.width == BoardView.doneRailWidth)
        #expect(view.cellForTesting(.done) == nil, "no card cell while folded")
        #expect(try workingWidth(view) > expandedWorking)
        // The archive stays reachable and the count still reads from the rail.
        #expect(first(NSButton.self, in: rail, identifier: "show-archive") != nil)
        #expect(rail.subviews.contains { countLabel(in: $0) })
    }

    private func countLabel(in view: NSView) -> Bool {
        if let field = view as? NSTextField, field.stringValue == "1" { return true }
        return view.subviews.contains { countLabel(in: $0) }
    }

    @Test("the second click expands DONE back to a full column")
    func toggleTwiceRestoresColumn() throws {
        let view = freshBoard()
        view.setDoneCollapsed(true)
        let toggle = try #require(first(NSButton.self, in: view, identifier: "done-collapse-toggle"))
        toggle.performClick(nil)
        view.layoutSubtreeIfNeeded()
        #expect(!view.isDoneCollapsed)
        #expect(view.cellForTesting(.done) != nil)
        #expect(first(NSView.self, in: view, identifier: "done-rail") == nil)
    }

    @Test("the fold survives a relaunch: a new board reads it back from defaults")
    func foldIsPersisted() throws {
        let defaults = UserDefaults.scratch
        let view = freshBoard(defaults: defaults)
        view.setDoneCollapsed(true)
        let relaunched = BoardView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 720), defaults: defaults)
        #expect(relaunched.isDoneCollapsed)
        relaunched.render(cards: [])
        relaunched.layoutSubtreeIfNeeded()
        #expect(first(NSView.self, in: relaunched, identifier: "done-rail") != nil)
    }
}

private extension UserDefaults {
    /// A throwaway suite per test, so no board fold leaks between tests.
    static var scratch: UserDefaults { UserDefaults(suiteName: "done-rail-\(UUID().uuidString)")! }
}
