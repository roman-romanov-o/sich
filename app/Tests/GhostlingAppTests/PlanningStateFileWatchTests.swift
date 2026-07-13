import AppKit
import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// TC-INT-010/011/012 — the PlanningStateReader ↔ FileWatcher wiring: an external
/// write to the bound folder re-parses via the existing watcher cadence (no new poll
/// loop), and a burst of writes coalesces to the last content without racing.
@MainActor
struct PlanningStateFileWatchTests {
    @Test func externalWriteRefreshesTheStepperViaTheWatcher() throws {
        let folder = try fixture(readme: seed(designDecisions: "Pending"))
        let view = PlanningModeView(reader: PlanningStateReader())
        view.show(card: card(folder))
        #expect(view.state?.nextIncomplete?.step == .designDecisions)

        try seed(designDecisions: "Done")
            .write(to: readme(folder), atomically: true, encoding: .utf8)
        view.fireWatchersForTesting()

        let decide = view.state?.steps.first { $0.step == .designDecisions }
        #expect(decide?.status == .complete)
        #expect(view.state?.nextIncomplete?.step == .codeChanges)
    }

    @Test func rapidWritesCoalesceToTheLastContentWithoutCrashing() throws {
        let folder = try fixture(readme: seed(designDecisions: "Pending"))
        let view = PlanningModeView(reader: PlanningStateReader())
        view.show(card: card(folder))

        for value in ["Pending", "In Progress", "Done"] {
            try seed(designDecisions: value).write(to: readme(folder), atomically: true,
                                                   encoding: .utf8)
            view.fireWatchersForTesting()
        }

        let decide = view.state?.steps.first { $0.step == .designDecisions }
        #expect(decide?.status == .complete)
    }

    private func seed(designDecisions: String) -> String {
        """
        | Research | Done |
        | Task Description | Done |
        | User Stories | Done |
        | Design Decisions | \(designDecisions) |
        | Code Changes | Pending |
        """
    }

    private func card(_ folder: URL) -> BoardCard {
        BoardCard(sessionID: "planning", projectDir: folder.path, agent: .claude,
                  flow: .a, state: .idle, taskFolder: folder.path)
    }

    private func readme(_ folder: URL) -> URL { folder.appendingPathComponent("README.md") }

    private func fixture(readme content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try content.write(to: url.appendingPathComponent("README.md"), atomically: true,
                          encoding: .utf8)
        return url
    }
}
