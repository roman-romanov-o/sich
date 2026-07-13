import Foundation
import Testing
@testable import GhostlingCore

private final class StubRunner: TaskScaffoldRunning, @unchecked Sendable {
    let result: ProcessResult
    private(set) var invocation: (URL, [String], URL)?

    init(result: ProcessResult) {
        self.result = result
    }

    func run(executable: URL, arguments: [String], directory: URL) throws -> ProcessResult {
        invocation = (executable, arguments, directory)
        return result
    }
}

@Test func scaffolderReturnsReportedExistingFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("docs/tasks/task-09-new")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let runner = StubRunner(result: ProcessResult(
        exitCode: 0, standardOutput: "Created docs/tasks/task-09-new\n", standardError: ""
    ))

    let result = try TaskScaffolder(runner: runner).create(
        title: "New", projectDirectory: root, script: URL(fileURLWithPath: "/init_task.sh")
    )
    #expect(result == folder.standardizedFileURL)
}

@Test func scaffolderForwardsExactInvocation() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeFolder("docs/tasks/task-11-forwarded", in: root)
    let script = URL(fileURLWithPath: "/opt/saha/init_task.sh")
    let runner = StubRunner(result: ProcessResult(
        exitCode: 0, standardOutput: folder.path, standardError: ""
    ))

    _ = try TaskScaffolder(runner: runner).create(
        title: "Exact title", projectDirectory: root, script: script
    )

    #expect(runner.invocation?.0 == script)
    #expect(runner.invocation?.1 == ["Exact title"])
    #expect(runner.invocation?.2 == root)
}

@Test(arguments: ["", "Task created successfully\n"])
func scaffolderRejectsMissingOutput(_ output: String) throws {
    let runner = StubRunner(result: ProcessResult(
        exitCode: 0, standardOutput: output, standardError: ""
    ))
    #expect(throws: TaskScaffoldingError.missingTaskFolder) {
        try runnerScaffolder(runner).create(
            title: "New", projectDirectory: URL(fileURLWithPath: "/tmp"),
            script: URL(fileURLWithPath: "/init_task.sh")
        )
    }
}

@Test func scaffolderAcceptsAbsoluteReportedPath() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeFolder("elsewhere/task-12-absolute", in: root)
    let runner = StubRunner(result: ProcessResult(
        exitCode: 0, standardOutput: "Created \(folder.path)\n", standardError: ""
    ))

    let result = try runnerScaffolder(runner).create(
        title: "New", projectDirectory: root, script: URL(fileURLWithPath: "/init_task.sh")
    )
    #expect(result == folder.standardizedFileURL)
}

@Test(arguments: ["\"docs/tasks/task-13-quoted\"", "'docs/tasks/task-13-quoted'"])
func scaffolderAcceptsQuotedReportedPath(_ reportedPath: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeFolder("docs/tasks/task-13-quoted", in: root)
    let runner = StubRunner(result: ProcessResult(
        exitCode: 0, standardOutput: "Created \(reportedPath)\n", standardError: ""
    ))

    let result = try runnerScaffolder(runner).create(
        title: "New", projectDirectory: root, script: URL(fileURLWithPath: "/init_task.sh")
    )
    #expect(result == folder.standardizedFileURL)
}

@Test func scaffolderAcceptsQuotedPathContainingSpaces() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeFolder("docs/tasks/task-15-path with spaces", in: root)
    let runner = StubRunner(result: ProcessResult(
        exitCode: 0,
        standardOutput: "Created \"docs/tasks/task-15-path with spaces\"\n",
        standardError: ""
    ))

    let result = try runnerScaffolder(runner).create(
        title: "New", projectDirectory: root, script: URL(fileURLWithPath: "/init_task.sh")
    )
    #expect(result == folder.standardizedFileURL)
}

@Test func scaffolderRejectsNonexistentAndFilePaths() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("task-14-file")
    try "file".write(to: file, atomically: true, encoding: .utf8)

    for path in ["docs/tasks/task-14-missing", file.path] {
        let runner = StubRunner(result: ProcessResult(
            exitCode: 0, standardOutput: path, standardError: ""
        ))
        let expected = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        #expect(throws: TaskScaffoldingError.invalidTaskFolder(
            expected.path
        )) {
            try runnerScaffolder(runner).create(
                title: "New", projectDirectory: root,
                script: URL(fileURLWithPath: "/init_task.sh")
            )
        }
    }
}

/// Regression: the real init_task.sh prints two task- lines — the full relative path
/// first, then the bare folder name. `.last` grabbed the bare name and resolved it to a
/// nonexistent path (TaskScaffoldingError). Must pick the first (contract) line.
@Test func scaffolderPicksCreatedLineNotCurrentTaskLine() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makeFolder("docs/tasks/task-09-test-task-4", in: root)
    let scriptOutput = """
    Created task folder: docs/tasks/task-09-test-task-4
    Task ID: task-09
    Mode: full
    Current task set to: task-09-test-task-4

    Next step: /saha:research
    """
    let runner = StubRunner(result: ProcessResult(
        exitCode: 0, standardOutput: scriptOutput, standardError: ""
    ))

    let result = try runnerScaffolder(runner).create(
        title: "Test task 4", projectDirectory: root,
        script: URL(fileURLWithPath: "/init_task.sh")
    )
    #expect(result == folder.standardizedFileURL)
}

@Test func scaffolderReportsNonZeroExit() throws {
    let runner = StubRunner(result: ProcessResult(
        exitCode: 2, standardOutput: "", standardError: "duplicate"
    ))
    let scaffolder = TaskScaffolder(runner: runner)
    #expect(throws: TaskScaffoldingError.processFailed(exitCode: 2, message: "duplicate")) {
        try scaffolder.create(
            title: "New", projectDirectory: URL(fileURLWithPath: "/tmp"),
            script: URL(fileURLWithPath: "/init_task.sh")
        )
    }
}

@Test func foundationRunnerCapturesProcessContract() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("capture.sh")
    let contents = """
    #!/bin/sh
    printf 'cwd=%s args=%s|%s' "$PWD" "$1" "$2"
    printf 'runner-error' >&2
    exit 7
    """
    try contents.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: script.path
    )

    let result = try FoundationTaskScaffoldRunner().run(
        executable: script,
        arguments: ["first argument", "second"],
        directory: root
    )

    #expect(result.exitCode == 7)
    let fields = result.standardOutput.split(separator: " args=", maxSplits: 1)
    let reportedDirectory = String(try #require(fields.first?.dropFirst("cwd=".count)))
    #expect(fields.last == "first argument|second")
    #expect(FileManager.default.contentsEqual(atPath: reportedDirectory, andPath: root.path))
    #expect(result.standardError == "runner-error")
}

private func runnerScaffolder(_ runner: StubRunner) -> TaskScaffolder<StubRunner> {
    TaskScaffolder(runner: runner)
}

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeFolder(_ path: String, in root: URL) throws -> URL {
    let folder = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}
