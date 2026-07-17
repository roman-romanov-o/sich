import Foundation
import Yams

// saha/v2 task tracking: one `progress.yaml` per task is the machine-readable
// source of truth; the LikeC4 model under `model/` is frozen spec. This file
// decodes progress.yaml and maps it onto the existing `PlanningState` shape so
// PlanningModeView renders v2 tasks through the same pipeline as legacy ones.

public struct PlanningProgress: Codable, Equatable, Sendable {
    public struct StepEntry: Codable, Equatable, Sendable {
        public let status: String?
        public let artifacts: [String]?
        public let views: [String]?
    }

    public struct AcceptanceCriterion: Codable, Equatable, Sendable {
        public let id: String?
        public let text: String?
        public let verify: String?
        public let status: String?
        public let specs: [String]?
        public let tests: [String]?
    }

    public struct Story: Codable, Equatable, Sendable {
        public let id: String?
        public let title: String?
        public let view: String?
        public let priority: String?
        public let status: String?
        public let acceptanceCriteria: [AcceptanceCriterion]?

        enum CodingKeys: String, CodingKey {
            case id, title, view, priority, status
            case acceptanceCriteria = "acceptance_criteria"
        }
    }

    public struct Phase: Codable, Equatable, Sendable {
        public let id: String?
        public let title: String?
        public let view: String?
        public let status: String?
    }

    public let format: String
    public let task: String?
    public let title: String?
    public let status: String?
    public let planning: [String: StepEntry]?
    public let stories: [Story]?
    public let phases: [Phase]?
}

public enum PlanningProgressReader {
    static let formatMarker = "format: saha/v2"

    /// The v2 entry point: `nil` means "not a v2 task — use the legacy path".
    /// A progress.yaml that declares saha/v2 but fails to decode yields a state
    /// with every step `.malformed` (never a silent legacy fallback).
    public static func read(taskFolder: URL) -> PlanningState? {
        let file = taskFolder.appendingPathComponent("progress.yaml")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              text.contains(formatMarker) else { return nil }
        guard let progress = try? YAMLDecoder().decode(PlanningProgress.self, from: text) else {
            return malformedState(taskFolder: taskFolder)
        }
        return state(from: progress, taskFolder: taskFolder)
    }

    // MARK: - Mapping

    private static func malformedState(taskFolder: URL) -> PlanningState {
        let steps = PlanningStep.allCases.map {
            PlanningStepState(step: $0, status: .malformed, artifact: nil)
        }
        return PlanningState(taskFolder: taskFolder, steps: steps, artifacts: [], isV2: true)
    }

    static func stepStatus(_ raw: String?) -> PlanningStepStatus {
        switch raw {
        case "done", "skipped": .complete
        case "in_progress": .inProgress
        case "pending", nil: .pending
        default: .malformed
        }
    }

    static func storyStatus(_ raw: String?) -> PlanningStepStatus {
        switch raw {
        case "done", "ready": .complete
        case "in_progress": .inProgress
        default: .pending
        }
    }

    private static func state(from progress: PlanningProgress, taskFolder: URL) -> PlanningState {
        let planning = progress.planning ?? [:]
        var artifacts: [PlanningArtifactState] = []
        let steps = PlanningStep.allCases.map { step -> PlanningStepState in
            let entry = planning[step.wireName]
            let status = stepStatus(entry?.status)
            let stepArtifacts = artifactStates(
                for: step, entry: entry, progress: progress,
                stepStatus: status, taskFolder: taskFolder
            )
            artifacts.append(contentsOf: stepArtifacts)
            return PlanningStepState(step: step, status: status,
                                     artifact: stepArtifacts.first?.url)
        }
        return PlanningState(taskFolder: taskFolder, steps: steps,
                             artifacts: artifacts, isV2: true)
    }

    /// Which model file holds each step's LikeC4 views (relative to the task folder).
    static func modelFile(for step: PlanningStep) -> String? {
        switch step {
        case .taskDescription: "model/task.c4"
        case .userStories: "model/stories.c4"
        case .designDecisions: "model/decisions.c4"
        case .codeChanges: "model/contracts.c4"
        case .testSpecs: "model/test-specs.c4"
        case .implementationPlan: "model/phases.c4"
        case .research, .verify: nil
        }
    }

    private static func artifactStates(
        for step: PlanningStep,
        entry: PlanningProgress.StepEntry?,
        progress: PlanningProgress,
        stepStatus: PlanningStepStatus,
        taskFolder: URL
    ) -> [PlanningArtifactState] {
        switch step {
        case .research:
            return (entry?.artifacts ?? []).map { path in
                PlanningArtifactState(step: step,
                                      url: taskFolder.appendingPathComponent(path),
                                      status: stepStatus)
            }
        case .verify:
            let url = taskFolder.appendingPathComponent("progress.yaml")
            return [PlanningArtifactState(step: step, url: url, status: stepStatus,
                                          title: "Verification gates")]
        case .userStories:
            if let stories = progress.stories, !stories.isEmpty {
                return storyArtifacts(stories, taskFolder: taskFolder)
            }
            return viewArtifacts(entry, step: step, stepStatus: stepStatus,
                                 taskFolder: taskFolder)
        case .taskDescription, .designDecisions, .codeChanges, .testSpecs,
             .implementationPlan:
            return viewArtifacts(entry, step: step, stepStatus: stepStatus,
                                 taskFolder: taskFolder)
        }
    }

    private static func viewArtifacts(
        _ entry: PlanningProgress.StepEntry?,
        step: PlanningStep,
        stepStatus: PlanningStepStatus,
        taskFolder: URL
    ) -> [PlanningArtifactState] {
        guard let file = modelFile(for: step) else { return [] }
        let url = taskFolder.appendingPathComponent(file)
        return (entry?.views ?? []).map { view in
            PlanningArtifactState(step: step, url: url, status: stepStatus,
                                  viewID: view, title: view)
        }
    }

    private static func storyArtifacts(
        _ stories: [PlanningProgress.Story], taskFolder: URL
    ) -> [PlanningArtifactState] {
        let url = taskFolder.appendingPathComponent("model/stories.c4")
        return stories.compactMap { story in
            guard let view = story.view ?? story.id.map({ "\($0.lowercased())-flow" })
            else { return nil }
            let label = [story.id, story.title].compactMap(\.self)
                .joined(separator: " · ")
            return PlanningArtifactState(
                step: .userStories, url: url,
                status: storyStatus(story.status),
                viewID: view, title: label.isEmpty ? view : label
            )
        }
    }
}
