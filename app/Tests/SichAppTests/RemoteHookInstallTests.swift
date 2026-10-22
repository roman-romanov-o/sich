import Foundation
import Testing

@testable import SichApp
import SichCore

/// ts-int-02 (TC-INT-012..016, TC-INT-018) — US-005 AC-1, AC-2, AC-3, AC-5, AC-6.
///
/// Real: the install and probe argv builders, the SHA-256 comparand, the
/// four-state mapping, `PoolFirewall`, and the remote shell commands themselves.
/// Mocked: only the transport — `FixtureSSH` drops the ssh half of the argv and
/// runs the remote command locally against a temp directory that stands in for
/// the remote `$HOME`. No test dials a host.
@Suite("Remote hook install and probe")
struct RemoteHookInstallTests {

    // MARK: - AC-1: the bytes that land are the bytes we ship

    @Test("TC-INT-012 — installRemote lands our exact forwarder and patches the settings")
    func installedBytesAreIdenticalToOurs() throws {
        let far = try FixtureSSH()
        defer { far.tearDown() }

        #expect(HookInstaller.installRemote(spec: far.spec, runner: far))

        let landed = try #require(far.contents(of: .forwarder))
        #expect(landed == Data(HookInstaller.forwarderBody.utf8))
        // A PTY channel would have rewritten every LF on the way through, and the
        // host would then read `staleVersion` forever.
        #expect(!String(decoding: landed, as: UTF8.self).contains("\r\n"))
        #expect(far.isExecutable(.forwarder))

        let settings = try #require(far.json(of: .claudeSettings))
        let hooks = try #require(settings["hooks"] as? [String: Any])
        for event in HookInstaller.events {
            #expect(commands(in: hooks[event]).contains(HookInstaller.remoteForward),
                    "\(event) does not call the forwarder")
        }
    }

    @Test("TC-INT-012 — no PTY, and the payload never becomes a shell word")
    func theChannelIsPtyFreeAndCarriesBytesOnStdin() throws {
        let far = try FixtureSSH()
        defer { far.tearDown() }
        HookInstaller.installRemote(spec: far.spec, runner: far)

        #expect(!far.argvs.isEmpty)
        for argv in far.argvs {
            #expect(!argv.contains("-t"), "a PTY rewrites LF to CRLF: \(argv)")
            // `$HOME`, `$SICH_CARD_ID`, `$file` and `$@` all live in the forwarder;
            // any of them inside an argv would be expanded on the far side.
            #expect(!argv.contains { $0.contains("SICH_CARD_ID") })
        }
        #expect(far.stdinBytes.contains(Data(HookInstaller.forwarderBody.utf8)))
    }

    @Test("TC-INT-012 — an existing remote hook survives the merge")
    func remoteInstallPreservesTheUsersOwnHooks() throws {
        let far = try FixtureSSH()
        defer { far.tearDown() }
        try far.seedSettings(["hooks": ["Stop": [["matcher": "", "hooks": [
            ["type": "command", "command": "bash ~/my-own.sh"]
        ]]]]])

        HookInstaller.installRemote(spec: far.spec, runner: far)

        let hooks = try #require(far.json(of: .claudeSettings)?["hooks"] as? [String: Any])
        #expect(commands(in: hooks["Stop"]).contains("bash ~/my-own.sh"))
        #expect(commands(in: hooks["Stop"]).contains(HookInstaller.remoteForward))
    }

    // MARK: - AC-2 / AC-3: the state is probed, never remembered

    @Test("TC-INT-013 — a freshly installed host reads installed")
    func freshInstallReadsInstalled() throws {
        let far = try FixtureSSH()
        defer { far.tearDown() }
        HookInstaller.installRemote(spec: far.spec, runner: far)

        #expect(HookInstaller.remoteInstallState(spec: far.spec, runner: far) == .installed)
    }

    @Test("TC-INT-014 — the state follows the far side, with no local invalidation")
    func stateIsProbeDerivedNeverCached() throws {
        let far = try FixtureSSH()
        defer { far.tearDown() }
        HookInstaller.installRemote(spec: far.spec, runner: far)
        #expect(HookInstaller.remoteInstallState(spec: far.spec, runner: far) == .installed)

        // One byte edited on the host — nothing tells the app, and nothing has to.
        try far.append("# edited by hand\n", to: .forwarder)
        #expect(HookInstaller.remoteInstallState(spec: far.spec, runner: far) == .staleVersion)

        try far.remove(.forwarder)
        #expect(HookInstaller.remoteInstallState(spec: far.spec, runner: far) == .notInstalled)
    }

    @Test("TC-INT-015 / AC-3 — all four states are reachable, and unknown is not installed")
    func allFourStatesAreReachableAndUnknownIsDistinct() throws {
        let far = try FixtureSSH()
        defer { far.tearDown() }

        #expect(HookInstaller.remoteInstallState(spec: far.spec, runner: far) == .notInstalled)
        HookInstaller.installRemote(spec: far.spec, runner: far)
        #expect(HookInstaller.remoteInstallState(spec: far.spec, runner: far) == .installed)
        try far.append("drift\n", to: .forwarder)
        #expect(HookInstaller.remoteInstallState(spec: far.spec, runner: far) == .staleVersion)

        // The host goes down AFTER a good install: the probe fails, and the honest
        // answer is `unknown` — the previous `installed` must not survive it.
        far.transportDown = true
        let state = HookInstaller.remoteInstallState(spec: far.spec, runner: far)
        #expect(state == .unknown)
        #expect(state != .installed)
        #expect(state != .notInstalled)
        #expect(!state.isActionable, "installing over a link we could not read is guessing")
    }

    @Test("TC-INT-015 — bytes on the host that nothing invokes are not an install")
    func forwarderWithoutSettingsIsNotInstalled() throws {
        let far = try FixtureSSH()
        defer { far.tearDown() }
        HookInstaller.installRemote(spec: far.spec, runner: far)
        try far.seedSettings([:])

        #expect(HookInstaller.remoteInstallState(spec: far.spec, runner: far) == .notInstalled)
    }

    @Test("TC-INT-016 — the comparand is a hash of the bytes, computed on the laptop")
    func comparandIsAContentHash() {
        let ours = Data(HookInstaller.forwarderBody.utf8)
        #expect(RemoteHookProbe.fingerprint(ours) == RemoteHookProbe.fingerprint(ours))
        #expect(RemoteHookProbe.fingerprint(ours) != RemoteHookProbe.fingerprint(ours + Data([0x0a])))
        #expect(RemoteHookProbe.fingerprint(Data()).count == 64)
    }

    @Test("TC-INT-016 — a probe that failed is never read as a file that is absent")
    func failedProbeAndAbsentFileAreDifferentFacts() {
        let script = Data("x".utf8)
        #expect(RemoteHookProbe.state(
            forwarder: .failed, matching: script,
            settings: .bytes(Data()), referencesHook: { _ in true }) == .unknown)
        #expect(RemoteHookProbe.state(
            forwarder: .bytes(Data()), matching: script,
            settings: .bytes(Data()), referencesHook: { _ in true }) == .notInstalled)
        // The settings read failing is equally unknown — half an answer is none.
        #expect(RemoteHookProbe.state(
            forwarder: .bytes(script), matching: script,
            settings: .failed, referencesHook: { _ in true }) == .unknown)
    }

    // MARK: - AC-5 / AC-6: no new surface, and the firewall still holds

    @Test("TC-INT-018 / AC-6 — both argvs are generated from the spec and pass PoolFirewall")
    func argvsAreSpecGeneratedAndFirewallClean() throws {
        let spec = RemoteTmuxSpec(host: "host.invalid", user: "roman", port: 2200)
        for file in RemoteHookFile.allCases {
            for argv in [try RemoteTmuxCommand.installArgv(for: spec, file: file),
                         try RemoteTmuxCommand.probeArgv(for: spec, file: file)] {
                #expect(try PoolFirewall.classify(argv) == .interactive)
                #expect(argv.first == "/usr/bin/ssh")
                #expect(argv.contains("roman@host.invalid"))
                // Positionally consumed by its flag — never in ssh's option slot.
                #expect(argv[argv.firstIndex(of: "2200")! - 1] == "-p")
            }
        }
    }

    @Test("AC-6 — an option-shaped destination cannot reach either channel")
    func optionShapedDestinationIsRefusedOnBothChannels() {
        let payload = "-oProxyCommand=sh -c 'claude -p x'"
        let spec = RemoteTmuxSpec(host: payload)
        #expect(throws: RemoteTmuxCommand.Invalid.invalidDestination(payload)) {
            try RemoteTmuxCommand.installArgv(for: spec, file: .forwarder)
        }
        #expect(throws: RemoteTmuxCommand.Invalid.invalidDestination(payload)) {
            try RemoteTmuxCommand.probeArgv(for: spec, file: .forwarder)
        }
    }

    @Test("TC-INT-012 / AC-5 — nothing new is installed on the host, and no new trust surface")
    func installAddsNoRemoteBinary() throws {
        let far = try FixtureSSH()
        defer { far.tearDown() }
        HookInstaller.installRemote(spec: far.spec, runner: far)

        // What runs on the far side is POSIX plumbing over the operator's own ssh
        // identity — no fetch, no interpreter, no daemon, no port.
        let allowed: Set<String> = ["mkdir", "cat", "chmod", "mv", "exit"]
        for command in far.remoteCommands {
            for tool in Self.invokedTools(in: command) {
                #expect(allowed.contains(tool), "unexpected remote tool `\(tool)` in: \(command)")
            }
        }
        // …and the file that lands is the one the LOCAL install writes.
        let home = far.root.appendingPathComponent("local-home")
        #expect(HookInstaller.installGlobal(home: home))
        let local = try Data(contentsOf: home.appendingPathComponent(
            RemoteHookFile.forwarder.rawValue))
        #expect(try #require(far.contents(of: .forwarder)) == local)
    }

    /// The first word of every `&&`- or `;`-separated segment — i.e. what the far
    /// side actually EXECUTES, as opposed to the flags and paths it is handed.
    private static func invokedTools(in command: String) -> [String] {
        command.replacingOccurrences(of: "&&", with: ";")
            .split(separator: ";")
            .compactMap { $0.split(separator: " ").first.map(String.init) }
    }

    private func commands(in event: Any?) -> [String] {
        (event as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }
}

/// The far side of ssh: a temp directory playing the remote `$HOME`, with the
/// remote command run by a real `/bin/sh`. The transport is the only thing faked
/// — the command strings, the file layout, the modes and the bytes are real.
///
/// @unchecked Sendable: driven from one test thread at a time.
final class FixtureSSH: RemoteCommandRunner, @unchecked Sendable {
    let root: URL
    let home: URL
    let spec = RemoteTmuxSpec(host: "far.invalid", user: "roman")

    /// Every argv the code under test handed to the transport.
    private(set) var argvs: [[String]] = []
    /// Everything that rode stdin.
    private(set) var stdinBytes: [Data] = []
    /// ssh refuses / times out — the state that must read `unknown`.
    var transportDown = false

    var remoteCommands: [String] { argvs.compactMap(\.last) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-remote-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    func run(argv: [String], input: Data?) -> RemoteCommandResult? {
        argvs.append(argv)
        if let input { stdinBytes.append(input) }
        // ssh itself exits 255 when it cannot reach the host — the failure the
        // probe must never mistake for "the file is not there".
        guard !transportDown else { return RemoteCommandResult(exitCode: 255, standardOutput: Data()) }
        guard let command = argv.last else { return nil }
        return execute(command, input: input)
    }

    private func execute(_ command: String, input: Data?) -> RemoteCommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        let stdin = Pipe()
        process.standardInput = stdin
        guard (try? process.run()) != nil else { return nil }
        if let input { stdin.fileHandleForWriting.write(input) }
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RemoteCommandResult(exitCode: process.terminationStatus, standardOutput: data)
    }

    // MARK: - inspecting the far side

    func url(_ file: RemoteHookFile) -> URL { home.appendingPathComponent(file.rawValue) }

    func contents(of file: RemoteHookFile) -> Data? { try? Data(contentsOf: url(file)) }

    func json(of file: RemoteHookFile) -> [String: Any]? {
        guard let data = contents(of: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    func isExecutable(_ file: RemoteHookFile) -> Bool {
        FileManager.default.isExecutableFile(atPath: url(file).path)
    }

    func seedSettings(_ cfg: [String: Any]) throws {
        let path = url(.claudeSettings)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: cfg).write(to: path)
    }

    func append(_ text: String, to file: RemoteHookFile) throws {
        let handle = try FileHandle(forWritingTo: url(file))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func remove(_ file: RemoteHookFile) throws {
        try FileManager.default.removeItem(at: url(file))
    }
}
