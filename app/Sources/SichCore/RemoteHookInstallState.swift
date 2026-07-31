import CryptoKit
import Foundation

/// Whether the hook forwarder on a remote host is ours, someone else's, or
/// simply unknown because the probe never got an answer (US-005 AC-3).
///
/// The two facts underneath are probe-derived and must never be collapsed:
/// *is the link up* and *are the remote hooks the bytes we ship*. A cached
/// "I ran installRemote once" flag answers neither — a host reinstalled, a
/// forwarder edited by hand, or a CRLF-rewriting channel all make that flag lie.
public enum RemoteHookInstallState: String, Sendable, Equatable, CaseIterable {
    /// The probe read the remote forwarder and its bytes match ours.
    case installed
    /// The probe ran and found nothing. Actionable.
    case notInstalled
    /// The probe read the forwarder and the bytes DIFFER. Actionable.
    case staleVersion
    /// The probe itself failed (ssh refused, timed out, host down). Inert — and
    /// emphatically NOT installed; treating it as installed is the lie this case
    /// exists to prevent.
    case unknown

    /// True where a click can fix the situation. `unknown` is not actionable:
    /// installing over a link we could not read would be guessing.
    public var isActionable: Bool { self == .notInstalled || self == .staleVersion }

    /// The trailing half of the host chip. `nil` for `installed` — a healthy host
    /// shows its destination and nothing else.
    public var chipDetail: String? {
        switch self {
        case .installed: return nil
        case .notInstalled: return "hooks not installed"
        case .staleVersion: return "hooks outdated"
        case .unknown: return "hook status unknown"
        }
    }
}

/// The files the install and probe channels touch on the far side, as paths
/// relative to the remote `$HOME`. A closed set on purpose: no remote path is
/// ever composed from free text.
public enum RemoteHookFile: String, Sendable, CaseIterable {
    case forwarder = ".sich/sich-forward.sh"
    case claudeSettings = ".claude/settings.json"

    /// Mode applied before the atomic rename — the forwarder must be runnable.
    var mode: String {
        switch self {
        case .forwarder: return "755"
        case .claudeSettings: return "644"
        }
    }
}

/// The outcome of one remote read. `.failed` means the PROBE failed, which is a
/// different fact from "the file is not there" (`.bytes` of length zero).
public enum RemoteRead: Sendable, Equatable {
    case bytes(Data)
    case failed
}

/// One command's result. `nil` from a runner means the command never ran at all.
public struct RemoteCommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: Data

    public init(exitCode: Int32, standardOutput: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// The transport seam. Tests inject a fixture runner so no test dials a host.
public protocol RemoteCommandRunner: Sendable {
    /// Run `argv`, optionally feeding `input` on stdin. Returns `nil` when the
    /// command could not be launched at all.
    func run(argv: [String], input: Data?) -> RemoteCommandResult?
}

/// Reads remote hook state over an injected transport and maps it to the
/// four-state model. Pure except for the runner it is handed.
public enum RemoteHookProbe {

    /// Read one remote file. A nonzero exit is the TRANSPORT failing: the remote
    /// command ends in `exit 0`, so a missing file comes back as empty bytes.
    public static func read(
        _ file: RemoteHookFile, on spec: RemoteTmuxSpec, using runner: RemoteCommandRunner
    ) -> RemoteRead {
        guard let argv = try? RemoteTmuxCommand.probeArgv(for: spec, file: file),
              let result = runner.run(argv: argv, input: nil), result.succeeded
        else { return .failed }
        return .bytes(result.standardOutput)
    }

    /// The four-state mapping. `referencesHook` decides whether the remote
    /// settings actually call our forwarder — the JSON shape lives with the
    /// installer that writes it, not here.
    public static func state(
        forwarder: RemoteRead,
        matching script: Data,
        settings: RemoteRead,
        referencesHook: (Data) -> Bool
    ) -> RemoteHookInstallState {
        guard case .bytes(let installed) = forwarder, case .bytes(let config) = settings else {
            return .unknown
        }
        guard !installed.isEmpty else { return .notInstalled }
        guard fingerprint(installed) == fingerprint(script) else { return .staleVersion }
        return referencesHook(config) ? .installed : .notInstalled
    }

    /// The comparand, computed on the laptop over the bytes we ship. A hash and
    /// not a version string: an older install and a CRLF-rewritten one are both
    /// "not our bytes", and neither announces itself.
    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The real transport: plain `ssh`, no PTY.
///
/// PTY-freeness is load-bearing, not incidental. A PTY rewrites LF to CRLF on
/// the way through, so the bytes that land differ from the bytes we hashed and
/// every host reads `staleVersion` forever. `Process` allocates none, and the
/// argv builders emit no `-t`.
public struct SSHCommandRunner: RemoteCommandRunner {

    /// Positive opt-in set ONLY by the real executable entry point — never by
    /// tests, so `swift test` can never reach the network.
    /// nonisolated(unsafe): written once at process start, before first use.
    public nonisolated(unsafe) static var spawningEnabled = false

    public init() {}

    public func run(argv: [String], input: Data?) -> RemoteCommandResult? {
        guard Self.spawningEnabled, let executable = argv.first else { return nil }
        guard (try? PoolFirewall.classify(argv)) != nil else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = stdin
        guard (try? process.run()) != nil else { return nil }

        if let input { stdin.fileHandleForWriting.write(input) }
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RemoteCommandResult(exitCode: process.terminationStatus, standardOutput: data)
    }
}
