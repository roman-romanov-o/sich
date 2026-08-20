import Foundation
import Testing
@testable import SichCore

/// ts-int-04 (TC-INT-007..011) — the tmux env binding, on a REAL tmux server.
///
/// Only ssh is mocked: the command the app generates is run against a local tmux
/// on a private socket instead of a remote one, which is the same tmux behaviour
/// being asserted. Nothing here dials a host.
///
/// The load-bearing case is TC-INT-007: a launch command sets ONE shell's process
/// env, not the tmux SESSION env, so asserting on the argv alone would ship AC-2
/// green while every pane the operator opens later (`Ctrl-b c`) is unbound.
@Suite("Remote tmux session env (real tmux)", .serialized)
struct RemoteTmuxSessionEnvTests {

    static let cardA = "6E7B0C1A-0000-4000-8000-00000000000A"
    static let cardB = "6E7B0C1A-0000-4000-8000-00000000000B"

    // MARK: - TC-INT-007 / AC-2 — the second pane

    @Test("a pane opened LATER in the same session inherits SICH_CARD_ID")
    func laterPaneCarriesTheCardID() throws {
        guard let tmux = try LocalTmux.orSkip() else { return }
        defer { tmux.tearDown() }
        let session = "sich-int-007"

        try tmux.attach(RemoteTmuxCommand.argv(
            for: RemoteTmuxSpec(host: "h", sessionName: session), cardID: Self.cardA))
        #expect(tmux.waitForSession(session))

        // The "Ctrl-b c" equivalent: a pane tmux spawns AFTER the launch shell.
        #expect(try tmux.cardID(inNewPaneOf: session) == Self.cardA)
    }

    // MARK: - TC-INT-008 / DD-002 — set-environment, no version floor

    @Test("the binding rides set-environment, never new-session -e (tmux >= 3.2)")
    func bindingUsesSetEnvironmentNotDashE() throws {
        let argv = try RemoteTmuxCommand.argv(
            for: RemoteTmuxSpec(host: "h", sessionName: "s"), cardID: Self.cardA)
        let remote = try #require(argv.last)
        // `new-session -e` needs tmux >= 3.2; Ubuntu 20.04 ships 3.0a, where it is a
        // usage error — the session never starts at all.
        #expect(!remote.contains("new-session -A -D -s 's' -e"))
        #expect(remote.contains("tmux set-environment SICH_CARD_ID"))

        guard let tmux = try LocalTmux.orSkip() else { return }
        defer { tmux.tearDown() }
        try tmux.attach(argv)
        #expect(tmux.waitForSession("s"))
        // The SESSION environment — the thing later panes are spawned from.
        #expect(tmux.showEnvironment("s") == "SICH_CARD_ID=\(Self.cardA)")
    }

    // MARK: - TC-INT-009 / edge case 1 — -A attaches, the command is IGNORED

    @Test("-A on a live session ignores the command: stale env, and the probe says so")
    func attachToLiveSessionIgnoresTheBinding() throws {
        guard let tmux = try LocalTmux.orSkip() else { return }
        defer { tmux.tearDown() }
        let session = "sich-int-009"
        let spec = RemoteTmuxSpec(host: "h", sessionName: session)

        try tmux.attach(RemoteTmuxCommand.argv(for: spec, cardID: Self.cardA))
        #expect(tmux.waitForSession(session))

        // A SECOND card reusing the name: -A attaches, so `set-environment` never runs
        // and the pane keeps card A's id. That is a card-modeling bug (name reuse),
        // not an identity one — and it is exactly why the collision must be surfaced.
        try tmux.attach(RemoteTmuxCommand.argv(for: spec, cardID: Self.cardB))
        #expect(tmux.showEnvironment(session) == "SICH_CARD_ID=\(Self.cardA)")
        #expect(try tmux.cardID(inNewPaneOf: session) == Self.cardA)

        let key = try RemoteSessionKey.make(for: spec)
        #expect(RemoteSessionProbe.presence(
            of: key, cardID: Self.cardB, spec: spec, runner: tmux.runner) == .foreign)
    }

    // MARK: - TC-INT-010 / edge case 4 — a hand-made session is not bound silently

    @Test("a pre-existing hand-made session is surfaced, never silently bound")
    func handMadeSessionIsSurfaced() throws {
        guard let tmux = try LocalTmux.orSkip() else { return }
        defer { tmux.tearDown() }
        let session = "sich-int-010"
        // The operator's own session, made before Sich ever ran.
        #expect(tmux.run(["new-session", "-d", "-s", session, "sh -c 'sleep 60'"]).status == 0)

        let spec = RemoteTmuxSpec(host: "h", sessionName: session)
        let key = try RemoteSessionKey.make(for: spec)
        #expect(tmux.showEnvironment(session) == nil)   // carries no binding at all
        #expect(RemoteSessionProbe.presence(
            of: key, cardID: Self.cardA, spec: spec, runner: tmux.runner) == .foreign)
    }

    @Test("an unused name probes ABSENT, so a first open proceeds")
    func freeNameProbesAbsent() throws {
        guard let tmux = try LocalTmux.orSkip() else { return }
        defer { tmux.tearDown() }
        let spec = RemoteTmuxSpec(host: "h", sessionName: "sich-int-010-free")
        let key = try RemoteSessionKey.make(for: spec)
        #expect(RemoteSessionProbe.presence(
            of: key, cardID: Self.cardA, spec: spec, runner: tmux.runner) == .absent)
    }

    // MARK: - TC-INT-011 / AC-4 — (host, sanitized name) is the identity

    @Test("the key is (host, SANITIZED name) — lossy folding cannot hide a collision")
    func keyIsHostPlusSanitizedName() throws {
        let dotted = try RemoteSessionKey.make(
            for: RemoteTmuxSpec(host: "build-box", sessionName: "my.proj"))
        let spaced = try RemoteSessionKey.make(
            for: RemoteTmuxSpec(host: "build-box", sessionName: "my proj"))
        // sanitizeSessionName folds "." and " " to "-": two different typed names ARE
        // one tmux session, and -A would attach both cards to it.
        #expect(dotted == spaced)
        #expect(dotted.session == "my-proj")
        #expect(dotted.sessionID == "remote/build-box/my-proj")

        let elsewhere = try RemoteSessionKey.make(
            for: RemoteTmuxSpec(host: "other-box", sessionName: "my.proj"))
        #expect(elsewhere != dotted)   // the same name on another host is another session
        #expect(RemoteSessionKey.parse(sessionID: dotted.sessionID) == dotted)
        #expect(RemoteSessionKey.parse(sessionID: "9f2b-local") == nil)
    }
}

// MARK: - harness

/// A real tmux server on a private socket, driven through the argv the app emits.
final class LocalTmux {
    let executable: String
    let root: URL
    private var attached: [Process] = []

    private init(executable: String) throws {
        self.executable = executable
        // Short on purpose: tmux's socket is a unix path capped at ~104 bytes, and
        // `NSTemporaryDirectory()` alone already spends half of that.
        self.root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("sich-tmux-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The harness, or `nil` after recording a LOUD known issue — a machine without
    /// tmux must never let TC-INT-007..011 pass silently.
    static func orSkip() throws -> LocalTmux? {
        guard let executable = discover() else {
            withKnownIssue("tmux is not installed — `brew install tmux` to run ts-int-04") {
                Issue.record("tmux missing: TC-INT-007..011 did not run")
            }
            return nil
        }
        return try LocalTmux(executable: executable)
    }

    private static func discover() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return candidates
            .map { ($0 as NSString).appendingPathComponent("tmux") }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func tearDown() {
        _ = run(["kill-server"])
        attached.forEach { $0.terminate() }
        try? FileManager.default.removeItem(at: root)
    }

    /// The environment the far-side login shell would have: our private socket dir,
    /// tmux on PATH, and emphatically NO inherited `SICH_CARD_ID` — a pane must get
    /// its binding from tmux, not from the test runner's own environment.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TMUX_TMPDIR"] = root.path
        env["PATH"] = (executable as NSString).deletingLastPathComponent + ":"
            + (env["PATH"] ?? "/usr/bin:/bin")
        env["SHELL"] = "/bin/sh"
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "SICH_CARD_ID")
        return env
    }

    /// ssh mocked away: the far-side command runs locally, against this tmux.
    var runner: RemoteCommandRunner { LocalTmuxRunner(environment: environment) }

    /// Run the generated argv the way `ssh -t` would — under a PTY, because tmux
    /// refuses to attach without one. `script` is the PTY; the command is byte-for-byte
    /// the string the app puts on the wire.
    func attach(_ argv: [String]) throws {
        guard let remote = argv.last else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", remote]
        process.environment = environment
        process.standardInput = Pipe()      // held open: `exec $SHELL -il` must not see EOF
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        attached.append(process)
    }

    @discardableResult
    func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func waitForSession(_ name: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if run(["has-session", "-t", "=\(name)"]).status == 0 { return true }
            usleep(50_000)
        }
        return false
    }

    /// The SESSION environment entry, or `nil` when the session carries none.
    func showEnvironment(_ name: String) -> String? {
        let result = run(["show-environment", "-t", "=\(name)", "SICH_CARD_ID"])
        guard result.status == 0, result.output.contains("=") else { return nil }
        return result.output
    }

    /// Open a NEW window in the session — the `Ctrl-b c` the operator presses — and
    /// report what `SICH_CARD_ID` that pane actually sees.
    func cardID(inNewPaneOf session: String, timeout: TimeInterval = 10) throws -> String {
        let out = root.appendingPathComponent("pane-\(UUID().uuidString).env")
        #expect(run([
            "new-window", "-t", "=\(session)", "-d",
            "printenv SICH_CARD_ID > '\(out.path)'; touch '\(out.path).done'",
        ]).status == 0)
        let done = out.path + ".done"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !FileManager.default.fileExists(atPath: done) {
            usleep(50_000)
        }
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Stands in for `SSHCommandRunner`: strips the ssh wrapper and runs the far-side
/// command locally. The command string itself is the app's, unmodified.
private struct LocalTmuxRunner: RemoteCommandRunner {
    let environment: [String: String]

    func run(argv: [String], input: Data?) -> RemoteCommandResult? {
        guard let command = argv.last, argv.first == "/usr/bin/ssh" else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RemoteCommandResult(exitCode: process.terminationStatus, standardOutput: data)
    }
}
