import Foundation

public enum PlanningStep: String, CaseIterable, Sendable {
    case research = "Research"
    case taskDescription = "Task Description"
    case userStories = "User Stories"
    case designDecisions = "Design Decisions"
    case codeChanges = "Code Changes"
    case testSpecs = "Test Specs"
    case implementationPlan = "Implementation Plan"
    case verify = "Verify"

    public var command: String {
        switch self {
        case .research: "/saha:research"
        case .taskDescription: "/saha:task"
        case .userStories: "/saha:stories"
        case .designDecisions: "/saha:decide"
        case .codeChanges: "/saha:contracts"
        case .testSpecs: "/saha:test-specs"
        case .implementationPlan: "/saha:plan"
        case .verify: "/saha:verify"
        }
    }

    /// snake_case identity shared with saha's `plan-status --json` `checks[].name`.
    public var wireName: String {
        switch self {
        case .research: "research"
        case .taskDescription: "task_description"
        case .userStories: "user_stories"
        case .designDecisions: "design_decisions"
        case .codeChanges: "code_changes"
        case .testSpecs: "test_specs"
        case .implementationPlan: "implementation_plan"
        case .verify: "verify"
        }
    }

    public init?(wireName: String) {
        guard let match = Self.allCases.first(where: { $0.wireName == wireName }) else { return nil }
        self = match
    }
}

public enum PlanningStepStatus: String, Sendable {
    case pending
    case inProgress
    case complete
    case malformed
}

public struct PlanningStepState: Equatable, Sendable {
    public let step: PlanningStep
    public let status: PlanningStepStatus
    public let artifact: URL?
}

public struct PlanningArtifactState: Equatable, Sendable {
    public let step: PlanningStep
    public let url: URL
    public let status: PlanningStepStatus
    /// saha/v2: the LikeC4 view id this review item deep-links to (`us-001-flow`).
    /// `nil` = a markdown artifact rendered as a document (the legacy path, and
    /// research files in v2). When set, `url` is the model file holding the view.
    public let viewID: String?
    /// saha/v2 display title ("US-001 · Board renders"); `nil` = use the file name.
    public let title: String?

    public init(step: PlanningStep, url: URL, status: PlanningStepStatus,
                viewID: String? = nil, title: String? = nil) {
        self.step = step
        self.url = url
        self.status = status
        self.viewID = viewID
        self.title = title
    }

    /// Stable identity for selection + ReviewStore keys: the view id for diagram
    /// items, the file name for markdown items.
    public var reviewKey: String { viewID ?? url.lastPathComponent }

    public var displayTitle: String { title ?? url.lastPathComponent }
}

public struct PlanningState: Equatable, Sendable {
    public let taskFolder: URL
    public let steps: [PlanningStepState]
    public let artifacts: [PlanningArtifactState]
    /// True when this state came from a `format: saha/v2` progress.yaml — the task's
    /// spec is a LikeC4 model under `model/` and diagram items carry `viewID`s.
    public let isV2: Bool

    public init(taskFolder: URL, steps: [PlanningStepState],
                artifacts: [PlanningArtifactState], isV2: Bool = false) {
        self.taskFolder = taskFolder
        self.steps = steps
        self.artifacts = artifacts
        self.isV2 = isV2
    }

    public var nextIncomplete: PlanningStepState? {
        steps.first { $0.status != .complete }
    }

    public func artifacts(for step: PlanningStep) -> [PlanningArtifactState] {
        artifacts.filter { $0.step == step }
    }
}

/// Optional preferred state source: runs `saha plan-status <task-id> --json`.
/// Returns stdout data on exit 0, `nil` on any failure (old saha, missing binary,
/// non-zero exit) so the reader falls back to marker scraping silently.
public protocol PlanningStatusRunning: Sendable {
    func run(taskFolder: URL) -> Data?
}

public struct SahaPlanStatusRunner: PlanningStatusRunning {
    public init() {}

    public func run(taskFolder: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["saha", "plan-status", taskFolder.lastPathComponent, "--json"]
        process.currentDirectoryURL = projectRoot(from: taskFolder)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private func projectRoot(from taskFolder: URL) -> URL {
        // docs/tasks/task-XX -> project root
        taskFolder.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

public struct PlanningStateReader: Sendable {
    private let jsonRunner: PlanningStatusRunning?

    /// `jsonRunner` defaults to `nil` so pure marker parsing stays deterministic; the
    /// app injects `SahaPlanStatusRunner()` to prefer saha's JSON contract (US-003 AC3).
    public init(jsonRunner: PlanningStatusRunning? = nil) {
        self.jsonRunner = jsonRunner
    }

    public func read(taskFolder: URL) -> PlanningState {
        // saha/v2 tasks carry a `format: saha/v2` progress.yaml — the single
        // source of truth, preferred over both the JSON runner and markers.
        if let v2 = PlanningProgressReader.read(taskFolder: taskFolder) {
            return v2
        }
        if let data = jsonRunner?.run(taskFolder: taskFolder),
           let state = decodeJSON(data, folder: taskFolder) {
            return state
        }
        return readMarkers(taskFolder: taskFolder)
    }

    private func decodeJSON(_ data: Data, folder: URL) -> PlanningState? {
        guard let payload = try? JSONDecoder().decode(PlanStatusJSON.self, from: data) else {
            return nil
        }
        let byName = Dictionary(payload.checks.map { ($0.name, $0.status) },
                                uniquingKeysWith: { first, _ in first })
        let steps = PlanningStep.allCases.map { step -> PlanningStepState in
            let status: PlanningStepStatus = switch byName[step.wireName] {
            case "passed": .complete
            case .some: .pending
            case nil: .malformed
            }
            return PlanningStepState(
                step: step, status: status, artifact: primaryArtifactURL(for: step, folder: folder)
            )
        }
        return PlanningState(taskFolder: folder, steps: steps, artifacts: artifactStates(in: folder))
    }

    private func readMarkers(taskFolder: URL) -> PlanningState {
        let readme = taskFolder.appendingPathComponent("README.md")
        let table = (try? String(contentsOf: readme, encoding: .utf8)) ?? ""
        let malformedReadme = FileManager.default.fileExists(atPath: readme.path) && table.isEmpty
        let steps = PlanningStep.allCases.map { step in
            let artifact = primaryArtifactURL(for: step, folder: taskFolder)
            let status = status(for: step, table: table, artifact: artifact,
                                malformedReadme: malformedReadme)
            return PlanningStepState(step: step, status: status, artifact: artifact)
        }
        return PlanningState(
            taskFolder: taskFolder, steps: steps, artifacts: artifactStates(in: taskFolder)
        )
    }

    private func status(
        for step: PlanningStep,
        table: String,
        artifact: URL?,
        malformedReadme: Bool
    ) -> PlanningStepStatus {
        if let row = table.split(separator: "\n").first(where: {
            $0.localizedCaseInsensitiveContains("| \(step.rawValue) |")
        }) {
            let value = row.lowercased()
            if value.contains("done") || value.contains("complete") || value.contains("[x]") {
                return .complete
            }
            if value.contains("progress") || value.contains("review") { return .inProgress }
            if value.contains("pending") || value.contains("[ ]") { return .pending }
            return .malformed
        }
        if malformedReadme { return .malformed }
        return artifactStatus(artifact: artifact, step: step)
    }

    private func artifactStatus(artifact: URL?, step: PlanningStep) -> PlanningStepStatus {
        guard let artifact, artifact.pathExtension == "md",
              FileManager.default.fileExists(atPath: artifact.path) else {
            return .pending
        }
        guard let text = try? String(contentsOf: artifact, encoding: .utf8) else {
            return .malformed
        }
        if text.range(of: #"\*\*Status:\*\*\s*(Done|Complete|Approved)"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            return .complete
        }
        return text.isEmpty ? .malformed : .inProgress
    }

    private func primaryArtifactURL(for step: PlanningStep, folder: URL) -> URL? {
        switch step {
        case .taskDescription: return folder.appendingPathComponent("task-description.md")
        case .research: return firstMarkdown(in: folder.appendingPathComponent("research"))
        case .userStories: return firstMarkdown(in: folder.appendingPathComponent("user-stories"))
        case .designDecisions:
            return firstMarkdown(in: folder.appendingPathComponent("design-decisions"))
        case .codeChanges: return firstMarkdown(in: folder.appendingPathComponent("code-changes"))
        case .testSpecs: return firstMarkdown(in: folder.appendingPathComponent("test-specs"))
        case .implementationPlan:
            return firstMarkdown(in: folder.appendingPathComponent("implementation-plan"))
        case .verify:
            let readme = folder.appendingPathComponent("README.md")
            return FileManager.default.fileExists(atPath: readme.path) ? readme : nil
        }
    }

    private func artifactStates(in folder: URL) -> [PlanningArtifactState] {
        PlanningStep.allCases.flatMap { step in
            artifactURLs(for: step, folder: folder).map { url in
                PlanningArtifactState(step: step, url: url, status: artifactStatus(artifact: url, step: step))
            }
        }
    }

    private func artifactURLs(for step: PlanningStep, folder: URL) -> [URL] {
        switch step {
        case .taskDescription:
            let url = folder.appendingPathComponent("task-description.md")
            return FileManager.default.fileExists(atPath: url.path) ? [url] : []
        case .research: return markdownFiles(in: folder.appendingPathComponent("research"))
        case .userStories: return markdownFiles(in: folder.appendingPathComponent("user-stories"))
        case .designDecisions:
            return markdownFiles(in: folder.appendingPathComponent("design-decisions"))
        case .codeChanges: return markdownFiles(in: folder.appendingPathComponent("code-changes"))
        case .testSpecs: return markdownFiles(in: folder.appendingPathComponent("test-specs"))
        case .implementationPlan:
            return markdownFiles(in: folder.appendingPathComponent("implementation-plan"))
        case .verify:
            let url = folder.appendingPathComponent("README.md")
            return FileManager.default.fileExists(atPath: url.path) ? [url] : []
        }
    }

    private func firstMarkdown(in directory: URL) -> URL? {
        markdownFiles(in: directory).first
    }

    private func markdownFiles(in directory: URL) -> [URL] {
        let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return urls?.filter { $0.pathExtension == "md" && $0.lastPathComponent != "README.md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }
}

private struct PlanStatusJSON: Decodable {
    struct Check: Decodable {
        let name: String
        let status: String
    }
    let checks: [Check]
    let nextStep: String?
    let complete: Bool

    enum CodingKeys: String, CodingKey {
        case checks
        case nextStep = "next_step"
        case complete
    }
}
