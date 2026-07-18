import Foundation
import Testing

@testable import GhostlingCore

/// The write-back path: Planning Mode approvals land in progress.yaml as surgical
/// line patches — never a decode→re-encode round trip, which would drop keys the
/// Swift structs don't model (`created`, `mode`, `gaps`, `iterations`) and every
/// comment. These tests pin that only the intended line changes, and that the
/// writer refuses outside `status: planning` (execution-phase files belong to the
/// saha manager agent alone).
struct PlanningProgressWritebackTests {
    private func fixture(progress: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saha-v2-wb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try progress.write(to: url.appendingPathComponent("progress.yaml"),
                           atomically: true, encoding: .utf8)
        return url
    }

    private func yaml(at folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent("progress.yaml"),
                   encoding: .utf8)
    }

    /// Block-style stories with AC statuses, comments, and keys the reader drops.
    private let blockYAML = """
    format: saha/v2
    task: task-11-sample
    title: Sample task
    created: 2026-07-17
    mode: full
    status: planning
    planning:
      research:            {status: done, artifacts: [research/analysis.md]}
      user_stories:        {status: in_progress, views: [us-001-flow, us-002-flow]}
      test_specs:          {status: pending, views: [], gaps: []}
      verify:              {status: pending}
    stories:
      - id: US-001
        title: Board renders stories
        view: us-001-flow
        status: ready
        acceptance_criteria:
          - id: AC-1
            text: "status: draft appears in prose here"
            verify: automated
            status: pending
      - id: US-002
        title: Deep-link opens the view
        view: us-002-flow
        status: draft
        acceptance_criteria:
          - id: AC-1
            verify: manual
            status: pending
    iterations: []
    """

    @Test func approveStoryFlipsDraftToReadyAndTouchesOnlyThatLine() throws {
        let folder = try fixture(progress: blockYAML)
        let before = blockYAML.components(separatedBy: "\n")

        #expect(PlanningProgressWriteback.approveStory(taskFolder: folder,
                                                       reviewKey: "us-002-flow"))

        let after = try yaml(at: folder).components(separatedBy: "\n")
        #expect(after.count == before.count)
        let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
        #expect(changed.count == 1)
        #expect(changed.first?.element.0 == "    status: draft")
        #expect(changed.first?.element.1 == "    status: ready")
        // AC statuses, the prose containing "status: draft", and the unknown keys
        // (created/mode/iterations) all survive untouched.
        #expect(try yaml(at: folder).contains("created: 2026-07-17"))
        #expect(try yaml(at: folder).contains(#"text: "status: draft appears in prose here""#))
    }

    @Test func approveStoryHandlesInlineFlowItems() throws {
        let folder = try fixture(progress: """
        format: saha/v2
        status: planning
        planning:
          user_stories: {status: in_progress, views: [us-001-flow]}
        stories:
          - {id: US-001, title: First story, view: us-001-flow, status: draft}
        """)

        #expect(PlanningProgressWriteback.approveStory(taskFolder: folder,
                                                       reviewKey: "us-001-flow"))
        #expect(try yaml(at: folder)
            .contains("- {id: US-001, title: First story, view: us-001-flow, status: ready}"))
    }

    @Test func approveStoryIsANoOpWhenAlreadyReady() throws {
        let folder = try fixture(progress: blockYAML)
        #expect(!PlanningProgressWriteback.approveStory(taskFolder: folder,
                                                        reviewKey: "us-001-flow"))
        #expect(try yaml(at: folder) == blockYAML)
    }

    @Test func writerRefusesWhenTaskIsExecuting() throws {
        let executing = blockYAML.replacingOccurrences(of: "status: planning",
                                                       with: "status: executing")
        let folder = try fixture(progress: executing)
        #expect(!PlanningProgressWriteback.approveStory(taskFolder: folder,
                                                       reviewKey: "us-002-flow"))
        #expect(!PlanningProgressWriteback.markStepDone(taskFolder: folder,
                                                        step: .userStories))
        #expect(try yaml(at: folder) == executing)
    }

    @Test func writerRefusesLegacyTasks() throws {
        let folder = try fixture(progress: "status: planning\ntask: legacy\n")
        #expect(!PlanningProgressWriteback.approveStory(taskFolder: folder,
                                                        reviewKey: "us-001-flow"))
    }

    @Test func markStepDoneUpgradesInlineEntryKeepingSiblingKeys() throws {
        let folder = try fixture(progress: blockYAML)

        #expect(PlanningProgressWriteback.markStepDone(taskFolder: folder,
                                                       step: .userStories))

        let text = try yaml(at: folder)
        #expect(text.contains(
            "user_stories:        {status: done, views: [us-001-flow, us-002-flow]}"))
        // Other steps and the top-level status stay untouched.
        #expect(text.contains("research:            {status: done, artifacts:"))
        #expect(text.contains("verify:              {status: pending}"))
        #expect(text.hasPrefix("format: saha/v2\ntask: task-11-sample"))
        #expect(text.contains("\nstatus: planning\n"))
    }

    @Test func markStepDoneHandlesBlockStyleEntries() throws {
        let folder = try fixture(progress: """
        format: saha/v2
        status: planning
        planning:
          design_decisions:
            status: in_progress
            views: [decisions]
        """)

        #expect(PlanningProgressWriteback.markStepDone(taskFolder: folder,
                                                       step: .designDecisions))
        #expect(try yaml(at: folder).contains("    status: done"))
    }

    @Test func markStepDoneLeavesDoneAndSkippedAlone() throws {
        let folder = try fixture(progress: blockYAML)
        #expect(!PlanningProgressWriteback.markStepDone(taskFolder: folder, step: .research))
        #expect(try yaml(at: folder) == blockYAML)
    }
}
