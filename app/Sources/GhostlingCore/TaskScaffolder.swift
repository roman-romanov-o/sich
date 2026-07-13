import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol TaskScaffoldRunning: Sendable {
    func run(executable: URL, arguments: [String], directory: URL) throws -> ProcessResult
}

public protocol TaskFolderScaffolding: Sendable {
    func create(title: String, projectDirectory: URL, script: URL) throws -> URL
}

public enum TaskScaffoldingError: Error, Sendable, Equatable {
    case processFailed(exitCode: Int32, message: String)
    case missingTaskFolder
    case invalidTaskFolder(String)
}

public struct TaskScaffolder<Runner: TaskScaffoldRunning>: @unchecked Sendable {
    private let runner: Runner
    private let fileManager: FileManager

    public init(runner: Runner, fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func create(
        title: String,
        projectDirectory: URL,
        script: URL
    ) throws -> URL {
        let result = try runner.run(
            executable: script, arguments: [title], directory: projectDirectory
        )
        guard result.exitCode == 0 else {
            throw TaskScaffoldingError.processFailed(
                exitCode: result.exitCode,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard let path = reportedTaskFolder(in: result.standardOutput)
        else { throw TaskScaffoldingError.missingTaskFolder }

        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : projectDirectory.appendingPathComponent(path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              url.lastPathComponent.hasPrefix("task-")
        else { throw TaskScaffoldingError.invalidTaskFolder(url.path) }
        return url.standardizedFileURL
    }

    private func reportedTaskFolder(in output: String) -> String? {
        // The FIRST task- token is the script's contract line ("Created task folder:
        // docs/tasks/task-09-…"); later lines echo the bare folder name ("Current task
        // set to: task-09-…") which resolves to a nonexistent path. Take the first.
        let pattern = #"(?:"([^"]*task-[^"]*)"|'([^']*task-[^']*)'|(\S*task-\S*))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: output, range: NSRange(output.startIndex..., in: output)
              )
        else { return nil }

        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            if range.location != NSNotFound, let swiftRange = Range(range, in: output) {
                return String(output[swiftRange])
            }
        }
        return nil
    }
}

extension TaskScaffolder: TaskFolderScaffolding {}

public struct FoundationTaskScaffoldRunner: TaskScaffoldRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], directory: URL) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ),
            standardError: String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
        )
    }
}
