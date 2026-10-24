import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String

    public init(exitCode: Int32, standardOutput: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
    }
}

/// Runs a child process to completion and captures its output. Injectable so the
/// git-driven provisioning paths can be exercised without a real subprocess.
public protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], directory: URL) throws -> ProcessResult
}

public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], directory: URL) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        // Nothing reads stderr; a pipe nobody drains would block a chatty child.
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
        )
    }
}
