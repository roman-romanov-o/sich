import AppKit
import Foundation
import GhostlingCore
import Testing
@testable import GhostlingApp

@MainActor
struct DrillInSidebarTests {
    @Test func renderingARealDiffDoesNotActivateCrossHierarchyConstraints() {
        let diff = """
        diff --git a/Sources/Thing.swift b/Sources/Thing.swift
        --- a/Sources/Thing.swift
        +++ b/Sources/Thing.swift
        @@ -1 +1 @@
        -let value = "old"
        +let value = "new"
        """
        let turn = TurnDiff(
            sessionID: "session", iteration: 1, timestamp: .now, unifiedDiff: diff)
        let sidebar = DrillInSidebar(frame: NSRect(x: 0, y: 0, width: 300, height: 600))

        sidebar.render(turns: [turn])
        sidebar.layoutSubtreeIfNeeded()

        #expect(sidebar.subviews.isEmpty == false)
    }
}
