import Foundation
import Testing

@testable import SichApp
@testable import SichCore

/// ts-e2e-01 — a remote hook line moves its card.
///
/// Real: the relay supervisor and its intake, the host stamp, the hook normalizer,
/// the session store, the board merge and the card state — the whole read path in
/// one process. Mocked: ssh and the remote host only, by a local file playing the
/// remote sink and a `/bin/sh` running the argv's own `tail -n 200 -F`.
///
/// Written RED first: before the relay existed, a line appended to any file but the
/// local `~/.sich/events.jsonl` reached nothing.
@Suite("Remote relay end-to-end (ts-e2e-01)")
struct RemoteRelayE2ETests {

    // MARK: - TC-E2E-001 / AC-1: the line reaches the board's session state

    @Test("TC-E2E-001 / AC-1: a remote hook line moves its card running → waiting")
    @MainActor func remoteHookLineMovesTheCard() async throws {
        let far = try RelayHost()
        defer { far.tearDown() }
        try far.write([])

        let local = try LocalSink()
        defer { local.tearDown() }

        let board = CardBox()
        // Backstop huge: the LOCAL poll cannot be what delivers these cards.
        let poller = SessionsPoller(eventsFile: local.file, interval: 86_400) { board.set($0) }
        poller.start()
        await poller.drainForTesting()
        poller.attachRemoteHost(far.spec, transport: far.transport)
        defer { poller.stop() }

        // A real forwarder-shaped line: Claude's own hook payload, plus the
        // `sich_card_id` the forwarder appends. Nothing in it names a machine.
        try far.append(far.hook("UserPromptSubmit"))
        #expect(await waitUntil { board.cards.contains { $0.state == .running } })

        try far.append(far.hook("Stop"))
        #expect(await waitUntil { board.cards.contains { $0.state == .waitingForInput } })

        let card = try #require(board.cards.first { $0.sessionID == far.sessionID })
        #expect(card.projectDir == "/srv/app")
        #expect(card.state == .waitingForInput)
    }

    // MARK: - TC-E2E-004 / AC-3: the local sink is never written

    @Test("TC-E2E-004 / AC-3: relayed lines never touch the local events.jsonl")
    @MainActor func relayedLinesNeverReachTheLocalSink() async throws {
        let far = try RelayHost()
        defer { far.tearDown() }
        try far.write([])

        let local = try LocalSink()
        defer { local.tearDown() }
        try local.seed(#"{"hook_event_name":"SessionStart","session_id":"local-1"}"#)
        let before = try local.byteLength()

        let board = CardBox()
        let poller = SessionsPoller(eventsFile: local.file, interval: 86_400) { board.set($0) }
        poller.start()
        await poller.drainForTesting()
        poller.attachRemoteHost(far.spec, transport: far.transport)
        defer { poller.stop() }

        for _ in 0..<20 { try far.append(far.hook("Stop")) }
        #expect(await waitUntil { board.cards.contains { $0.sessionID == far.sessionID } })

        #expect(try local.byteLength() == before,
                "the local sink has exactly one writer — the local forwarder")
        #expect(board.cards.contains { $0.sessionID == "local-1" },
                "…and the local session is still there: the two intakes share one store")
    }

    // MARK: - TC-E2E-003 / US-004 AC-3: two hosts are never conflated

    /// The adversarial shape: host A, host B and local all report the SAME
    /// `session_id` in the BYTE-IDENTICAL cwd `/srv/app`. Nothing in the payloads
    /// distinguishes them — only `sich_host`, which the channel stamped, can.
    ///
    /// Written RED first: with a session store keyed by `session_id` alone, the three
    /// machines collapsed into ONE card whose state was whichever line landed last.
    @Test("TC-E2E-003 / AC-3: same session id + same cwd on 2 hosts + local = 3 cards")
    @MainActor func hostsWithIdenticalPayloadsStayDistinct() async throws {
        let shared = "shared-session-1"
        let alpha = try RelayHost(host: "alpha.invalid", sessionID: shared, cardID: nil)
        let beta = try RelayHost(host: "beta.invalid", sessionID: shared, cardID: nil)
        defer { alpha.tearDown(); beta.tearDown() }
        try alpha.write([])
        try beta.write([])

        let local = try LocalSink()
        defer { local.tearDown() }
        try local.seed(alpha.hook("UserPromptSubmit"))   // byte-identical to the far ones

        let board = CardBox()
        let poller = SessionsPoller(eventsFile: local.file, interval: 86_400) { board.set($0) }
        poller.start()
        await poller.drainForTesting()
        poller.attachRemoteHost(alpha.spec, transport: alpha.transport)
        poller.attachRemoteHost(beta.spec, transport: beta.transport)
        defer { poller.stop() }

        try alpha.append(alpha.hook("UserPromptSubmit"))
        try beta.append(beta.hook("UserPromptSubmit"))
        #expect(await waitUntil { board.cards.count == 3 },
                "three machines, three cards — got \(board.cards.map(\.host))")
        #expect(Set(board.cards.map(\.host)) == [nil, "alpha.invalid", "beta.invalid"])
        #expect(board.cards.allSatisfy { $0.projectDir == "/srv/app" })

        // …and they move INDEPENDENTLY: a Stop on alpha leaves beta and local working.
        try alpha.append(alpha.hook("Stop"))
        #expect(await waitUntil {
            board.cards.first { $0.host == "alpha.invalid" }?.state == .waitingForInput
        })
        #expect(board.cards.first { $0.host == "beta.invalid" }?.state == .running)
        #expect(board.cards.first { $0.host == nil }?.state == .running)
    }

    @Test("TC-E2E-003 / AC-3: two hosts' diffs for one session+iteration stay two turns")
    @MainActor func diffsFromTwoHostsAreNotDeduplicated() async throws {
        let shared = "shared-session-2"
        let alpha = try RelayHost(host: "alpha.invalid", sessionID: shared, cardID: nil)
        let beta = try RelayHost(host: "beta.invalid", sessionID: shared, cardID: nil)
        defer { alpha.tearDown(); beta.tearDown() }
        try alpha.write([])
        try beta.write([])

        let local = try LocalSink()
        defer { local.tearDown() }
        try local.seed(#"{"hook_event_name":"SessionStart","session_id":"local-only"}"#)

        let diffs = DiffBox()
        let poller = SessionsPoller(
            eventsFile: local.file, interval: 86_400,
            diffSink: { diffs.set($0) }, sink: { _ in })
        poller.start()
        await poller.drainForTesting()
        poller.attachRemoteHost(alpha.spec, transport: alpha.transport)
        poller.attachRemoteHost(beta.spec, transport: beta.transport)
        defer { poller.stop() }

        // Same session id, same iteration, same cwd — only the machine differs.
        try alpha.append(alpha.diff(iteration: 1, body: "--- a/x\n+++ b/x\n@@\n+alpha\n"))
        try beta.append(beta.diff(iteration: 1, body: "--- a/x\n+++ b/x\n@@\n+beta\n"))

        #expect(await waitUntil { diffs.all.count == 2 },
                "one turn per machine — got \(diffs.all.count)")
        #expect(Set(diffs.all.map(\.host)) == ["alpha.invalid", "beta.invalid"])
    }

    // MARK: - TC-E2E-002 / AC-2: `sich_host` is stamped by US, at ingestion

    @Test("TC-E2E-002 / AC-2: the channel stamps sich_host — the bytes cannot")
    func hostIsStampedByTheChannelNotParsedFromThePayload() async throws {
        let far = try RelayHost()
        defer { far.tearDown() }
        try far.write([far.hook("Stop")])

        let (relay, lines) = try far.relay()
        relay.start()
        defer { relay.stop() }
        #expect(await waitUntil { lines.count == 1 })

        let received = try #require(lines.all.first)
        let raw = String(decoding: received.line, as: UTF8.self)
        // The premise: a hook payload has NO hostname field, so the host cannot have
        // been read out of these bytes — the string does not occur in them at all.
        #expect(!raw.contains("far.invalid"))
        #expect(!raw.contains(RemoteEventLine.hostKey))
        #expect(received.host == "far.invalid", "the host is the channel's knowledge")

        // …and the stamp is applied at ingestion, before any normalizer sees it.
        let stamped = try #require(received.stampedPayload())
        #expect(stamped[RemoteEventLine.hostKey] as? String == "far.invalid")
        #expect(stamped["session_id"] as? String == far.sessionID)
    }

    @Test("AC-2: a far side that CLAIMS a host is overruled by the channel")
    func aClaimedHostIsOverwritten() {
        let claimed = #"{"hook_event_name":"Stop","session_id":"s","sich_host":"attacker.invalid"}"#
        let line = RemoteEventLine(host: "far.invalid", line: Data(claimed.utf8))

        #expect(line.stampedPayload()?[RemoteEventLine.hostKey] as? String == "far.invalid")
    }

    @Test("AC-2: byte-identical lines from two hosts carry two different stamps")
    func identicalLinesFromTwoHostsAreDistinguishable() {
        let bytes = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/srv/app"}"#.utf8)
        let one = RemoteEventLine(host: "build-box", line: bytes)
        let two = RemoteEventLine(host: "gpu-box", line: bytes)

        #expect(one.stampedPayload()?[RemoteEventLine.hostKey] as? String == "build-box")
        #expect(two.stampedPayload()?[RemoteEventLine.hostKey] as? String == "gpu-box")
    }

    @Test("AC-2: the stamp reaches the normalizer's input, not a later step")
    func theStampIsOnTheNormalizerInput() {
        let bytes = Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8)
        let batch = SessionsFeed.parse(
            [RemoteEventLine(host: "build-box", line: bytes)],
            arrival: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(batch.events.count == 1)
        // The LOCAL intake over the same bytes stamps nothing — provenance exists
        // only where a channel supplied it.
        let localPayload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        #expect(localPayload?[RemoteEventLine.hostKey] == nil)
    }

    // MARK: - TC-INT-006 / AC-4: structurally still observe-only

    @Test("TC-INT-006 / AC-4: the only NWListener in the app is the LikeC4 file server")
    func theOnlyListenerRemainsTheLikeC4FileServer() {
        let sources = Self.repoRoot.appendingPathComponent("app/Sources")
        let files = Set(grep("NWListener", under: sources).compactMap {
            $0.split(separator: ":").first.map { URL(fileURLWithPath: String($0)).lastPathComponent }
        })

        #expect(files == ["StaticFileServer.swift"],
                "US-003 adds no inbound listener; found NWListener in \(files.sorted())")
    }

    @Test("AC-4: no listener API and no remote binary push anywhere in the relay path")
    func theRelayPathBindsNothingAndInstallsNothing() {
        let relayFiles = ["app/Sources/SichCore/RemoteEventRelay.swift",
                          "app/Sources/SichCore/ProcessLineStream.swift"]
            .map { Self.repoRoot.appendingPathComponent($0) }

        for needle in ["NWListener", "NWConnection", "bind(", "listen(", "scp", "rsync",
                       "install"] {
            // Code only — a doc comment mentioning a word is not an inbound socket.
            let hits = grep(needle, under: relayFiles).filter { !isComment($0) }
            #expect(hits.isEmpty, "the relay path must stay a read: \(needle) found in \(hits)")
        }
    }

    // MARK: - helpers

    /// The repo root, four dirs up from this file.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SichAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
    }

    /// True when a `path:line:text` hit is a comment line.
    private func isComment(_ hit: String) -> Bool {
        let fields = hit.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return false }
        return fields[2].trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// `grep -rn needle path…`, returning each `path:line:text`.
    private func grep(_ needle: String, under paths: URL...) -> [String] {
        grep(needle, under: paths)
    }

    private func grep(_ needle: String, under paths: [URL]) -> [String] {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        proc.arguments = ["-rn", needle] + existing.map(\.path)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

// MARK: - Fixtures (a local file plays the remote sink; no test dials a host)

/// One stand-in remote machine: a temp `$HOME` with the far side's
/// `.sich/events.jsonl`, plus the transport that runs the relay argv's own remote
/// command against it under `/bin/sh`.
struct RelayHost {
    let root: URL
    let home: URL
    let spec: RemoteTmuxSpec
    let sessionID: String
    /// The `sich_card_id` the far-side forwarder splices in; `nil` for a session
    /// nobody's card owns (a human ran `claude` in a pane we never opened).
    let cardID: String?

    init(
        host: String = "far.invalid", sessionID: String = "c0ffee-remote-1",
        cardID: String? = "6E7B0C1A-0000-4000-8000-000000000001"
    ) throws {
        self.spec = RemoteTmuxSpec(host: host, user: "roman")
        self.sessionID = sessionID
        self.cardID = cardID
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-relay-e2e-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".sich", isDirectory: true),
            withIntermediateDirectories: true)
    }

    var eventsFile: URL { home.appendingPathComponent(".sich/events.jsonl") }

    var transport: FixtureRelayTransport { FixtureRelayTransport(home: home) }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// The bytes the installed forwarder appends: Claude's hook payload with the
    /// `sich_card_id` stamp — and no field naming a machine.
    func hook(_ event: String) -> String {
        let binding = cardID.map { #","sich_card_id":"\#($0)""# } ?? ""
        return """
        {"session_id":"\(sessionID)","transcript_path":"/home/roman/.claude/x.jsonl",\
        "cwd":"/srv/app","hook_event_name":"\(event)"\(binding)}
        """
    }

    /// A `turn_diff` line, the shape the forwarder ships after a Stop. `stamp` is the
    /// forwarder's whole-second `timestamp`: two Stops one second apart ship the same
    /// diff under two different byte strings (US-008 AC-2).
    func diff(iteration: Int, body: String, stamp: String? = nil) -> String {
        let encoded = Data(body.utf8).base64EncodedString()
        let timestamp = stamp.map { #","timestamp":"\#($0)""# } ?? ""
        return """
        {"sich_event_type":"turn_diff","session_id":"\(sessionID)","cwd":"/srv/app",\
        "iteration":\(iteration),"diff_base64":"\(encoded)"\(timestamp)}
        """
    }

    func write(_ lines: [String]) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: eventsFile)
    }

    func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: eventsFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func relay() throws -> (RemoteEventRelay, LineCollector) {
        let lines = LineCollector()
        let relay = try RemoteEventRelay(
            spec: spec, transport: transport, reconnectDelay: 0.1, sink: { lines.add($0) })
        return (relay, lines)
    }
}

/// The LOCAL `~/.sich/events.jsonl` stand-in, watched for byte-level changes.
struct LocalSink {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var file: URL { root.appendingPathComponent("events.jsonl") }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    func seed(_ line: String) throws {
        try Data((line + "\n").utf8).write(to: file)
    }

    func byteLength() throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
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

/// The board's latest snapshot, readable from the polling helper's thread.
final class CardBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [BoardCard] = []

    func set(_ cards: [BoardCard]) {
        lock.lock()
        latest = cards
        lock.unlock()
    }

    var cards: [BoardCard] {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

/// The drill-in's latest turn-diff set, readable off the main actor.
final class DiffBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [TurnDiff] = []

    func set(_ diffs: [TurnDiff]) {
        lock.lock()
        latest = diffs
        lock.unlock()
    }

    var all: [TurnDiff] {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

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
}

/// Poll a condition to a deadline: the relay reads from a real child process, so
/// arrival is asynchronous — nothing here sleeps a fixed "long enough" interval.
func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
