import Foundation
import Testing

@testable import SichCore

/// ts-int-03 — the relay transport: rotation, bounded replay, keepalive death, the
/// dedup memory bound, and the structural "still no listener" guarantee.
///
/// The relay supervisor and its line intake are REAL and driven against a real file
/// that is appended to and rotated; only the ssh child is stood in for — either by a
/// local `/bin/sh` running the argv's own remote command (so a real `tail -n 200 -F`
/// is what gets exercised) or, where an exit status is the subject, by a scripted
/// transport. No test dials a host.
@Suite("Remote event relay (ts-int-03)")
struct RemoteEventRelayTests {

    // MARK: - AC-5: the argv comes from a constrained spec and passes the firewall

    @Test("TC-INT-018 / AC-5: the relay argv is spec-generated and firewall-clean")
    func relayArgvIsSpecGeneratedAndFirewallClean() throws {
        let argv = try RemoteTmuxCommand.relayArgv(for: RemoteTmuxSpec(host: "build-box"))

        #expect(argv == [
            "/usr/bin/ssh",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "build-box",
            "tail -n 200 -F \"$HOME\"/'.sich/events.jsonl'",
        ])
        #expect(try PoolFirewall.classify(argv) == .interactive)
    }

    @Test("AC-5: port and identity thread through, and nothing else is caller-supplied")
    func relayArgvCarriesOnlySpecFields() throws {
        let spec = RemoteTmuxSpec(
            host: "10.0.0.5", user: "roman", port: 2222, identityFile: "/keys/id_ed25519")
        let argv = try RemoteTmuxCommand.relayArgv(for: spec)

        #expect(argv.contains(["-p", "2222"].joined()) == false)  // separate tokens, not fused
        let port = try #require(argv.firstIndex(of: "2222"))
        #expect(argv[port - 1] == "-p")
        let identity = try #require(argv.firstIndex(of: "/keys/id_ed25519"))
        #expect(argv[identity - 1] == "-i")
        #expect(argv[argv.count - 2] == "roman@10.0.0.5")
        // The remote command is a constant: no field of the spec reaches it.
        #expect(argv.last == "tail -n 200 -F \"$HOME\"/'.sich/events.jsonl'")
    }

    @Test("AC-5: an option-shaped destination is refused before any relay starts")
    func optionShapedDestinationIsRefused() {
        let evil = RemoteTmuxSpec(host: "-oProxyCommand=sh -c curl|sh")
        #expect(throws: RemoteTmuxCommand.Invalid.self) {
            try RemoteTmuxCommand.relayArgv(for: evil)
        }
        #expect(throws: RemoteTmuxCommand.Invalid.self) {
            _ = try RemoteEventRelay(
                spec: evil, transport: ScriptedTransport(), sink: { _ in })
        }
    }

    @Test("TC-INT-006 / AC-4: the relay opens an OUTBOUND read and nothing else")
    func relayAsksSSHForNoListenerAndNoRemoteBinary() throws {
        let argv = try RemoteTmuxCommand.relayArgv(for: RemoteTmuxSpec(host: "build-box"))

        // -R/-L/-D would open a socket (a reverse forward is an inbound path in
        // disguise); -t would allocate a PTY and rewrite LF to CRLF.
        for forbidden in ["-R", "-L", "-D", "-t", "-N", "-W"] {
            #expect(!argv.contains(forbidden), "relay argv must not carry \(forbidden)")
        }
        // The far side runs one tool, and it is a reader. Nothing is installed.
        let command = try #require(argv.last)
        let tools = command.split(whereSeparator: { " \t;|&".contains($0) })
            .map(String.init)
            .filter { !$0.hasPrefix("-") && !$0.hasPrefix("\"") && !$0.hasPrefix("'") }
            .filter { Int($0) == nil }
        #expect(tools == ["tail"])
    }

    // MARK: - TC-INT-001..003: a real `tail -F` against a real file

    @Test("TC-INT-001: a rotation (mv -f) is followed, with no stale byte offset")
    func rotationIsFollowedWithoutAStaleOffset() async throws {
        let host = try RelayHost()
        defer { host.tearDown() }
        // A big pre-rotation file, so a remembered offset would land PAST the end of
        // the small file that replaces it and skip everything written after.
        try host.write((1...50).map { "{\"n\":\($0),\"pad\":\"\(String(repeating: "x", count: 200))\"}" })

        let (relay, lines) = try host.relay()
        relay.start()
        defer { relay.stop() }
        #expect(await waitUntil { lines.count == 50 })

        // Exactly what the forwarder does at 5 MiB: write a fresh file and mv over.
        try host.rotate(to: ["{\"n\":\"after-rotation\"}"])
        try host.append("{\"n\":\"post-rotation-append\"}")

        #expect(await waitUntil { lines.text.contains("after-rotation") })
        #expect(await waitUntil { lines.text.contains("post-rotation-append") })
        #expect(lines.all.allSatisfy { $0.host == "far.invalid" })
    }

    @Test("TC-INT-002 / edge case 3: an absent remote log is NOT `unreachable`")
    func absentRemoteLogIsNotUnreachable() async throws {
        let host = try RelayHost()
        defer { host.tearDown() }
        // No events.jsonl at all: the far side simply has not fired a hook yet.

        let (relay, lines) = try host.relay()
        relay.start()
        defer { relay.stop() }

        // Give the child real time to fail if it were going to.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(relay.health != .unreachable, "silence is not a dead link")
        #expect(lines.count == 0)

        // …and when the log finally appears, it is picked up with no restart.
        try host.write(["{\"hook_event_name\":\"Stop\",\"session_id\":\"late\"}"])
        #expect(await waitUntil { lines.text.contains("late") })
        #expect(relay.health == .streaming)
    }

    @Test("TC-INT-003 / edge case 2: history replayed on connect is bounded at 200")
    func historyIsBoundedAtTwoHundredLines() async throws {
        let host = try RelayHost()
        defer { host.tearDown() }
        try host.write((1...500).map { "{\"n\":\($0)}" })

        let (relay, lines) = try host.relay()
        relay.start()
        defer { relay.stop() }
        #expect(await waitUntil { lines.count == RemoteTmuxCommand.relayReplayLines })

        try await Task.sleep(nanoseconds: 200_000_000)   // nothing more may trickle in
        #expect(lines.count == 200)
        #expect(lines.text.contains("{\"n\":301}"))
        #expect(!lines.text.contains("{\"n\":300}"), "older history must not be re-ingested")
    }

    @Test("a multi-hundred-KB line survives the pipe read boundary intact")
    func aHugeLineArrivesWhole() async throws {
        let host = try RelayHost()
        defer { host.tearDown() }
        let huge = "{\"hook_event_name\":\"PostToolUse\",\"blob\":\"" +
            String(repeating: "d", count: 400_000) + "\"}"
        try host.write([huge, "{\"n\":\"after\"}"])

        let (relay, lines) = try host.relay()
        relay.start()
        defer { relay.stop() }
        #expect(await waitUntil { lines.count == 2 })
        #expect(lines.all[0].line == Data(huge.utf8), "a chunk boundary must not split a line")
    }

    // MARK: - TC-INT-004..005: liveness and the dedup memory bound

    @Test("TC-INT-004 / US-007.AC-2: ssh's own 255 (keepalive death) reaches `unreachable`")
    func keepaliveDeathReachesUnreachable() throws {
        let transport = ScriptedTransport()
        let relay = try RemoteEventRelay(
            spec: RemoteTmuxSpec(host: "far.invalid"), transport: transport,
            reconnectDelay: 3_600, sink: { _ in })
        relay.start()
        defer { relay.stop() }
        #expect(relay.health == .connecting)

        // ServerAliveInterval=15 × ServerAliveCountMax=3 expiring is ssh exiting 255.
        transport.finish(255)
        #expect(relay.health == .unreachable)
    }

    @Test("a REMOTE command failure is not a dead link — the host answered")
    func remoteCommandFailureIsNotUnreachable() throws {
        let transport = ScriptedTransport()
        let relay = try RemoteEventRelay(
            spec: RemoteTmuxSpec(host: "far.invalid"), transport: transport,
            reconnectDelay: 3_600, sink: { _ in })
        relay.start()
        defer { relay.stop() }

        transport.finish(1)   // e.g. `tail` gave up on the far side
        #expect(relay.health != .unreachable)
    }

    @Test("TC-INT-005: the dedup memory stays bounded under a long replay")
    func dedupMemoryStaysBounded() throws {
        let transport = ScriptedTransport()
        let lines = LineCollector()
        let relay = try RemoteEventRelay(
            spec: RemoteTmuxSpec(host: "far.invalid"), transport: transport,
            reconnectDelay: 3_600, sink: { lines.add($0) })
        relay.start()
        defer { relay.stop() }

        for batch in 0..<20 {
            transport.emit((0..<100).map { "{\"n\":\(batch * 100 + $0)}" })
        }
        #expect(lines.count == 2_000)
        #expect(relay.dedupWindowCount == RemoteEventRelay.dedupCapacity)

        // The newest line is remembered; one evicted long ago is not (that is the
        // price of a bound, and it is the right one: the replay window is 200).
        transport.emit(["{\"n\":1999}"])
        #expect(lines.count == 2_000, "a line still in the window must not be re-ingested")
        transport.emit(["{\"n\":0}"])
        #expect(lines.count == 2_001)
    }

    @Test("edge case 2: the 200-line replay after a reconnect is not re-ingested")
    func reconnectReplayIsDeduped() async throws {
        let transport = ScriptedTransport()
        let lines = LineCollector()
        let relay = try RemoteEventRelay(
            spec: RemoteTmuxSpec(host: "far.invalid"), transport: transport,
            reconnectDelay: 0.05, sink: { lines.add($0) })
        relay.start()
        defer { relay.stop() }

        let history = (1...200).map { "{\"n\":\($0)}" }
        transport.emit(history)
        #expect(lines.count == 200)

        transport.finish(255)                       // the link drops
        #expect(await waitUntil { transport.startCount == 2 })   // …and is redialled
        transport.emit(history)                     // `tail -n 200` replays the same tail
        #expect(lines.count == 200, "replayed history must not be ingested twice")

        transport.emit(["{\"n\":201}"])
        #expect(lines.count == 201)
        #expect(relay.health == .streaming, "bytes flowing again means the link is back")
    }

    @Test("stop() suppresses the reconnect its own child exit would cause")
    func stopSuppressesReconnect() async throws {
        let transport = ScriptedTransport()
        let relay = try RemoteEventRelay(
            spec: RemoteTmuxSpec(host: "far.invalid"), transport: transport,
            reconnectDelay: 0.05, sink: { _ in })
        relay.start()
        relay.stop()
        transport.finish(255)

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(transport.startCount == 1, "a stopped relay must never redial")
        #expect(transport.cancelCount == 1)
    }

    @Test("a transport that refuses to launch does not spin a reconnect loop")
    func refusedLaunchDoesNotSpin() async throws {
        // The shipped shape of a refusal: `SSHLineTransport.spawningEnabled` is false
        // everywhere but the real executable, so `swift test` never spawns an ssh.
        #expect(SSHLineTransport.spawningEnabled == false)
        #expect(SSHLineTransport().start(
            argv: try RemoteTmuxCommand.relayArgv(for: RemoteTmuxSpec(host: "far.invalid")),
            onLines: { _ in }, onExit: { _ in }) == nil)

        let transport = ScriptedTransport(refuseToStart: true)
        let relay = try RemoteEventRelay(
            spec: RemoteTmuxSpec(host: "far.invalid"), transport: transport,
            reconnectDelay: 0.02, sink: { _ in })
        relay.start()
        defer { relay.stop() }

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(transport.startCount == 1)
        #expect(relay.health == .unreachable)
    }
}

// MARK: - Fixtures (no test dials a host)

/// A local stand-in for one remote machine: a temp `$HOME` holding the far side's
/// `.sich/events.jsonl`, and a transport that runs the argv's OWN remote command
/// under `/bin/sh` with `HOME` pointed at it. The `tail -n 200 -F` under test is the
/// one the shipped argv asks for.
struct RelayHost {
    let root: URL
    let home: URL
    let spec = RemoteTmuxSpec(host: "far.invalid", user: "roman")

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-relay-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".sich", isDirectory: true),
            withIntermediateDirectories: true)
    }

    var eventsFile: URL { home.appendingPathComponent(RemoteTmuxCommand.remoteEventLog) }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    func write(_ lines: [String]) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: eventsFile)
    }

    func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: eventsFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// What the forwarder does at 5 MiB: a new file renamed over the old one.
    func rotate(to lines: [String]) throws {
        let next = eventsFile.appendingPathExtension("next")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: next)
        _ = try FileManager.default.replaceItemAt(eventsFile, withItemAt: next)
    }

    func relay() throws -> (RemoteEventRelay, LineCollector) {
        let lines = LineCollector()
        let relay = try RemoteEventRelay(
            spec: spec, transport: FixtureRelayTransport(home: home),
            reconnectDelay: 0.1, sink: { lines.add($0) })
        return (relay, lines)
    }
}

struct FixtureRelayTransport: RemoteLineTransport {
    let home: URL

    func start(
        argv: [String],
        onLines: @escaping @Sendable ([Data]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> RemoteLineStream? {
        guard let command = argv.last else { return nil }
        return ProcessLineStream(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
            onLines: onLines, onExit: onExit)
    }
}

/// A transport the test drives directly, for the cases whose subject is an exit
/// status or a reconnect rather than `tail`'s behaviour.
final class ScriptedTransport: RemoteLineTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var onLines: (@Sendable ([Data]) -> Void)?
    private var onExit: (@Sendable (Int32) -> Void)?
    private var starts = 0
    private var cancels = 0
    private let refuseToStart: Bool

    init(refuseToStart: Bool = false) {
        self.refuseToStart = refuseToStart
    }

    final class Stream: RemoteLineStream, @unchecked Sendable {
        private let onCancel: @Sendable () -> Void
        init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }

    func start(
        argv: [String],
        onLines: @escaping @Sendable ([Data]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> RemoteLineStream? {
        lock.lock()
        starts += 1
        lock.unlock()
        guard !refuseToStart else { return nil }
        lock.lock()
        self.onLines = onLines
        self.onExit = onExit
        lock.unlock()
        return Stream { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.cancels += 1
            self.lock.unlock()
        }
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels
    }

    func emit(_ lines: [String]) {
        lock.lock()
        let handler = onLines
        lock.unlock()
        handler?(lines.map { Data($0.utf8) })
    }

    func finish(_ code: Int32) {
        lock.lock()
        let handler = onExit
        lock.unlock()
        handler?(code)
    }
}

/// Thread-safe collector: the relay delivers on the reader's thread.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [RemoteEventLine] = []

    func add(_ batch: [RemoteEventLine]) {
        lock.lock()
        lines += batch
        lock.unlock()
    }

    var all: [RemoteEventLine] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var count: Int { all.count }

    var text: String { all.map { String(decoding: $0.line, as: UTF8.self) }.joined(separator: "\n") }
}

/// Poll a condition to a deadline — the relay's reader is a real child process, so
/// arrival is asynchronous; nothing here sleeps a fixed "long enough" interval.
func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
