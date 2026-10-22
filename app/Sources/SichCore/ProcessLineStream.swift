import Foundation

/// A long-lived child process read as a stream of whole `\n`-terminated lines.
///
/// Reassembly is the point: a pipe read boundary lands wherever the kernel put it,
/// and a hook line can run to kilobytes, so anything that treated one read as
/// one record would hand the JSON parser halves of a line. A trailing fragment is
/// held until its newline arrives, and an unterminated fragment at EOF is dropped
/// rather than delivered half-parsed.
///
/// Shared by the real ssh transport and, in tests (via `@testable`), by a local
/// stand-in that runs the same remote command against a temp directory — so the line
/// handling under test is the shipped one.
final class ProcessLineStream: RemoteLineStream, @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    /// Returns `nil` when the child could not be launched at all.
    init?(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        onLines: @escaping @Sendable ([Data]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let reader = output.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let lines = self.absorb(handle.availableData)
            if !lines.isEmpty { onLines(lines) }
        }
        process.terminationHandler = { [weak self] process in
            reader.readabilityHandler = nil
            // Whatever the child wrote just before exiting is still in the pipe.
            if let self, let rest = try? reader.readToEnd() {
                let lines = self.absorb(rest)
                if !lines.isEmpty { onLines(lines) }
            }
            onExit(process.terminationStatus)
        }
        guard (try? process.run()) != nil else {
            reader.readabilityHandler = nil
            process.terminationHandler = nil
            return nil
        }
    }

    func cancel() {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Append a chunk and cut off every complete line it finished.
    private func absorb(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}

/// The real relay transport: plain outbound `ssh`, no PTY.
///
/// PTY-freeness matters here for the same reason it does on the install channel — a
/// PTY rewrites LF to CRLF, which would corrupt every JSON line on the way in.
public struct SSHLineTransport: RemoteLineTransport {

    /// Positive opt-in set ONLY by the real executable entry point — never by tests,
    /// so `swift test` can never reach the network.
    /// nonisolated(unsafe): written once at process start, before first use.
    public nonisolated(unsafe) static var spawningEnabled = false

    public init() {}

    public func start(
        argv: [String],
        onLines: @escaping @Sendable ([Data]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> RemoteLineStream? {
        guard Self.spawningEnabled, let executable = argv.first else { return nil }
        guard (try? PoolFirewall.classify(argv)) != nil else { return nil }
        return ProcessLineStream(
            executable: executable, arguments: Array(argv.dropFirst()),
            onLines: onLines, onExit: onExit)
    }
}
