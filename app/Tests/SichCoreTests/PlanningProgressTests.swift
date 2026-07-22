import Foundation
import Testing

@testable import SichCore

/// saha/v2: `progress.yaml` is the single tracking source; the LikeC4 model under
/// `model/` is frozen spec. These tests pin the YAML → PlanningState mapping and the
/// detection boundary against the legacy marker path.
struct PlanningProgressTests {
    private func fixture(progress: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saha-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let progress {
            try progress.write(to: url.appendingPathComponent("progress.yaml"),
                               atomically: true, encoding: .utf8)
        }
        return url
    }

    private let sampleYAML = """
    format: saha/v2
    task: task-11-sample
    title: Sample task
    status: planning
    planning:
      research:            {status: done, artifacts: [research/analysis.md]}
      task_description:    {status: done, views: [task-context]}
      user_stories:        {status: in_progress, views: [us-001-flow, us-002-flow]}
      design_decisions:    {status: skipped, views: [decisions]}
      code_changes:        {status: pending, views: []}
      test_specs:          {status: pending, views: []}
      implementation_plan: {status: pending, views: []}
      verify:              {status: pending}
    stories:
      - id: US-001
        title: Board renders stories
        view: us-001-flow
        priority: must
        status: ready
        acceptance_criteria:
          - id: AC-1
            text: "Given a v2 task, the rail lists its stories"
            verify: automated
            status: pending
      - id: US-002
        title: Deep-link opens the view
        priority: should
        status: draft
    """

    @Test func mapsPlanningStepsFromProgressYAML() throws {
        let folder = try fixture(progress: sampleYAML)
        let state = PlanningStateReader().read(taskFolder: folder)

        #expect(state.isV2)
        #expect(state.steps.count == PlanningStep.allCases.count)
        func status(_ step: PlanningStep) -> PlanningStepStatus? {
            state.steps.first { $0.step == step }?.status
        }
        #expect(status(.research) == .complete)
        #expect(status(.taskDescription) == .complete)
        #expect(status(.userStories) == .inProgress)
        #expect(status(.designDecisions) == .complete)   // skipped counts as complete
        #expect(status(.codeChanges) == .pending)
        #expect(state.nextIncomplete?.step == .userStories)
    }

    @Test func storiesBecomeViewArtifactsWithStableReviewKeys() throws {
        let folder = try fixture(progress: sampleYAML)
        let state = PlanningStateReader().read(taskFolder: folder)
        let stories = state.artifacts(for: .userStories)

        #expect(stories.map(\.reviewKey) == ["us-001-flow", "us-002-flow"])
        #expect(stories.map(\.displayTitle) == [
            "US-001 · Board renders stories", "US-002 · Deep-link opens the view",
        ])
        // US-002 has no explicit view: — the id-derived default binds it.
        #expect(stories[1].viewID == "us-002-flow")
        #expect(stories[0].status == .complete)   // ready
        #expect(stories[1].status == .pending)    // draft
        // Both deep-link into the same frozen model file.
        #expect(stories.allSatisfy { $0.url.lastPathComponent == "stories.c4" })
    }

    @Test func nonStoryStepsMapViewsAndResearchMapsMarkdown() throws {
        let folder = try fixture(progress: sampleYAML)
        let state = PlanningStateReader().read(taskFolder: folder)

        let research = state.artifacts(for: .research)
        #expect(research.map(\.reviewKey) == ["analysis.md"])
        #expect(research[0].viewID == nil)   // markdown renders as a document

        let task = state.artifacts(for: .taskDescription)
        #expect(task.map(\.reviewKey) == ["task-context"])
        #expect(task[0].url.lastPathComponent == "task.c4")

        let decisions = state.artifacts(for: .designDecisions)
        #expect(decisions.map(\.reviewKey) == ["decisions"])
        #expect(decisions[0].url.lastPathComponent == "decisions.c4")

        let verify = state.artifacts(for: .verify)
        #expect(verify.map(\.displayTitle) == ["Verification gates"])
    }

    @Test func freshInitScaffoldReadsAsAllPendingNotMalformed() throws {
        // The exact shape scripts/init_task.sh writes on /saha:init.
        let folder = try fixture(progress: """
        format: saha/v2
        task: "task-01-toy-feature"
        title: "Toy Feature"
        created: "2026-07-18"
        mode: full
        status: planning

        planning:
          research:            { status: pending, artifacts: [] }
          task_description:    { status: pending, views: [] }
          user_stories:        { status: pending, views: [] }
          design_decisions:    { status: pending, views: [] }
          code_changes:        { status: pending, views: [] }
          test_specs:          { status: pending, views: [] }
          implementation_plan: { status: pending, views: [] }
          verify:              { status: pending }

        stories: []
        phases: []
        iterations: []
        """)
        let state = PlanningStateReader().read(taskFolder: folder)
        #expect(state.isV2)
        #expect(state.steps.allSatisfy { $0.status == .pending })
        #expect(state.artifacts(for: .userStories).isEmpty)
        #expect(state.nextIncomplete?.step == .research)
    }

    @Test func malformedYAMLWithMarkerNeverFallsBackToLegacy() throws {
        let folder = try fixture(progress: "format: saha/v2\nplanning: [not, a, map")
        // A legacy README that would read as all-Done must be ignored: the v2 marker
        // means the YAML is authoritative even when broken.
        let rows = PlanningStep.allCases.map { "| \($0.rawValue) | Done |" }
            .joined(separator: "\n")
        try rows.write(to: folder.appendingPathComponent("README.md"),
                       atomically: true, encoding: .utf8)

        let state = PlanningStateReader().read(taskFolder: folder)
        #expect(state.isV2)
        #expect(state.steps.allSatisfy { $0.status == .malformed })
        #expect(state.artifacts.isEmpty)
    }

    @Test func withoutTheMarkerTheLegacyPathIsUntouched() throws {
        let folder = try fixture(progress: "format: something-else\n")
        try "| Research | Done |".write(to: folder.appendingPathComponent("README.md"),
                                        atomically: true, encoding: .utf8)
        let state = PlanningStateReader().read(taskFolder: folder)
        #expect(!state.isV2)
        #expect(state.steps.first { $0.step == .research }?.status == .complete)
    }

    @Test func reviewKeyFallsBackToFileNameForMarkdownArtifacts() {
        let url = URL(fileURLWithPath: "/tmp/task/research/analysis.md")
        let markdown = PlanningArtifactState(step: .research, url: url, status: .pending)
        #expect(markdown.reviewKey == "analysis.md")
        #expect(markdown.displayTitle == "analysis.md")
        let diagram = PlanningArtifactState(step: .userStories, url: url, status: .pending,
                                            viewID: "us-001-flow", title: "US-001 · X")
        #expect(diagram.reviewKey == "us-001-flow")
        #expect(diagram.displayTitle == "US-001 · X")
    }
}
