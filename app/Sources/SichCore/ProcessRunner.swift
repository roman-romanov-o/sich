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
