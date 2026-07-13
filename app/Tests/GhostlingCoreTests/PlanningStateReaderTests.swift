import Foundation
import Testing

@testable import GhostlingCore

struct PlanningStateReaderTests {
    @Test func readsEveryPipelineStateFromDashboard() throws {
        let folder = try fixture()
        let rows = PlanningStep.allCases.enumerated().map { index, step in
            "| \(step.rawValue) | \(index == 0 ? "Done" : index == 1 ? "In Progress" : "Pending") |"
        }.joined(separator: "\n")
        try rows.write(to: folder.appendingPathComponent("README.md"), atomically: true,
                       encoding: .utf8)

        let state = PlanningStateReader().read(taskFolder: folder)

        #expect(state.steps.count == PlanningStep.allCases.count)
        #expect(state.steps[0].status == .complete)
        #expect(state.steps[1].status == .inProgress)
        #expect(state.steps.dropFirst(2).allSatisfy { $0.status == .pending })
    }

    @Test func marksUnknownDashboardValuesMalformed() throws {
        let folder = try fixture()
        try "| Research | banana |".write(
            to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        let state = PlanningStateReader().read(taskFolder: folder)
        #expect(state.steps.first { $0.step == .research }?.status == .malformed)
    }

    @Test func aSubsequentReadReflectsFileChanges() throws {
        let folder = try fixture()
        let readme = folder.appendingPathComponent("README.md")
        try "| Research | Pending |".write(to: readme, atomically: true, encoding: .utf8)
        let reader = PlanningStateReader()
        #expect(researchStatus(reader.read(taskFolder: folder)) == .pending)
        try "| Research | Done |".write(to: readme, atomically: true, encoding: .utf8)
        #expect(researchStatus(reader.read(taskFolder: folder)) == .complete)
    }

    // MARK: TC-UNIT-004/005 — next incomplete step

    @Test func nextIncompleteIsFirstUncompletedStepInPipelineOrder() throws {
        let folder = try fixture()
        let rows = "| Research | Done |\n| Task Description | Done |\n| User Stories | Done |"
        try rows.write(to: folder.appendingPathComponent("README.md"), atomically: true,
                       encoding: .utf8)
        let state = PlanningStateReader().read(taskFolder: folder)
        #expect(state.nextIncomplete?.step == .designDecisions)
    }

    @Test func allDoneHasNoNextIncomplete() throws {
        let folder = try fixture()
        let rows = PlanningStep.allCases.map { "| \($0.rawValue) | Done |" }
            .joined(separator: "\n")
        try rows.write(to: folder.appendingPathComponent("README.md"), atomically: true,
                       encoding: .utf8)
        let state = PlanningStateReader().read(taskFolder: folder)
        #expect(state.nextIncomplete == nil)
    }

    // MARK: TC-UNIT-006 — step → command table

    @Test func everyStepMapsToItsSlashCommand() {
        let expected: [PlanningStep: String] = [
            .research: "/saha:research", .taskDescription: "/saha:task",
            .userStories: "/saha:stories", .designDecisions: "/saha:decide",
            .codeChanges: "/saha:contracts", .testSpecs: "/saha:test-specs",
            .implementationPlan: "/saha:plan", .verify: "/saha:verify",
        ]
        for step in PlanningStep.allCases {
            #expect(step.command == expected[step])
        }
    }

    @Test func wireNamesRoundTrip() {
        for step in PlanningStep.allCases {
            #expect(PlanningStep(wireName: step.wireName) == step)
        }
        #expect(PlanningStep(wireName: "not_a_step") == nil)
    }

    @Test func exposesEveryMarkdownArtifactForReviewInStableOrder() throws {
        let folder = try fixture()
        let stories = folder.appendingPathComponent("user-stories", isDirectory: true)
        try FileManager.default.createDirectory(at: stories, withIntermediateDirectories: true)
        try "# Index".write(to: stories.appendingPathComponent("README.md"), atomically: true,
                            encoding: .utf8)
        try "# US-002\n\n**Status:** Draft".write(
            to: stories.appendingPathComponent("US-002-second.md"), atomically: true,
            encoding: .utf8
        )
        try "# US-001\n\n**Status:** Approved".write(
            to: stories.appendingPathComponent("US-001-first.md"), atomically: true,
            encoding: .utf8
        )

        let state = PlanningStateReader().read(taskFolder: folder)
        let artifacts = state.artifacts(for: .userStories)

        #expect(artifacts.map { $0.url.lastPathComponent } == [
            "US-001-first.md", "US-002-second.md",
        ])
        #expect(artifacts[0].status == .complete)
        #expect(artifacts[1].status == .inProgress)
        #expect(state.steps.first { $0.step == .userStories }?.artifact?.lastPathComponent
                == "US-001-first.md")
    }

    // MARK: TC-INT-011/012 — JSON preference and marker fallback

    @Test func prefersSahaJSONOverMarkers() throws {
        let folder = try fixture()
        // Markers alone would report Research pending; JSON says Research passed.
        try "| Research | Pending |".write(
            to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        let runner = StubRunner(json: """
        {"task_id":"t","checks":[
          {"name":"research","status":"passed"},
          {"name":"task_description","status":"passed"},
          {"name":"user_stories","status":"passed"},
          {"name":"design_decisions","status":"failed"},
          {"name":"code_changes","status":"failed"},
          {"name":"test_specs","status":"failed"},
          {"name":"implementation_plan","status":"failed"},
          {"name":"verify","status":"failed"}
        ],"next_step":"design_decisions","complete":false}
        """)
        let state = PlanningStateReader(jsonRunner: runner).read(taskFolder: folder)
        #expect(researchStatus(state) == .complete)
        #expect(state.nextIncomplete?.step == .designDecisions)
    }

    @Test func fallsBackToMarkersWhenSahaLacksTheCommand() throws {
        let folder = try fixture()
        try "| Research | Done |".write(
            to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        // Runner returns nil (old saha / unknown flag): must not surface an error.
        let state = PlanningStateReader(jsonRunner: StubRunner(json: nil))
            .read(taskFolder: folder)
        #expect(researchStatus(state) == .complete)
    }

    private func researchStatus(_ state: PlanningState) -> PlanningStepStatus? {
        state.steps.first { $0.step == .research }?.status
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct StubRunner: PlanningStatusRunning {
    let json: String?
    func run(taskFolder: URL) -> Data? { json?.data(using: .utf8) }
}
