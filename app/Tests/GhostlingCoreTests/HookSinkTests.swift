import Foundation
import Testing

@testable import GhostlingCore

/// Native hook sink (US-003) — the Swift port of `detector/{hook_receiver,jsonl_tail,
/// classifier,reconciler,registry}.py`, driven by an observe-only append-only file
/// (DD-002). These pin the durable tail (offset/rotation/partial line), the
/// `_HOOK_KIND` normalization + test-runner inference, the reconciler precedence +
/// staleness sweep, and (TC-INT-324) full parity against the frozen Python detector
/// on shared recorded sequences.
///
/// Harness rules (inherited): never spawns `claude -p`, never opens a port, never
/// reads the real `~/.ghostling`. Every case builds its own event file under the
/// test's temp dir, and injects `now`/`arrival` so staleness is deterministic.
///
/// `.serialized`: tail cases write + re-read shared temp files and persist an offset
/// sidecar; running serially keeps one case's file/offset from leaking into another.
@Suite("Native hook sink (port of the detector — US-003)", .serialized)
struct HookSinkTests {

    // MARK: - Fixture helpers

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// A fresh temp event file URL (the file itself is created on first append).
    private func makeEventsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostling-events-\(UUID().uuidString).jsonl")
    }

    /// Append one JSON line (newline-terminated) to `file`, exactly as the forwarder
    /// does under `O_APPEND`.
    private func append(_ json: String, to file: URL) throws {
        let line = Data((json + "\n").utf8)
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file)
        }
    }

    private func normalize(_ json: String, arrival: Date) -> SignalEvent? {
        HookNormalizer.normalize(Data(json.utf8), arrival: arrival)
    }

    // MARK: - TC-INT-320: append a Stop line → idle within one poll, NO server

    @Test("TC-INT-320: append a Stop line → session clears running status within one poll, no server")
    func appendStopLineMovesSessionToIdle() throws {
        let file = makeEventsFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let now = date("2026-06-16T12:00:00Z")
        try append(#"{"hook_event_name":"SessionStart","session_id":"S","timestamp":"2026-06-16T12:00:00+00:00"}"#, to: file)
        try append(#"{"hook_event_name":"Stop","session_id":"S","timestamp":"2026-06-16T12:00:05+00:00"}"#, to: file)

        let tail = HookEventTail(file: file)
        let store = HookSessionStore()
        store.ingest(tail.poll().compactMap { HookNormalizer.normalize($0, arrival: now) })

        // Stop clears active status. Notification/permission hooks carry "needs input".
        #expect(store.entry(for: "S")?.state == .idle)
    }

    // MARK: - TC-INT-321: _HOOK_KIND map parity (table)

    @Test("TC-INT-321: _HOOK_KIND map ported verbatim (Stop→stop, Notification→permission, …)")
    func hookKindMapParity() {
        let now = date("2026-06-16T12:00:00Z")
        let expected: [(String, SignalKind)] = [
            ("SessionStart", .sessionStart),
            ("UserPromptSubmit", .userInput),
            ("PreToolUse", .toolUse),
            ("PostToolUse", .toolUse),
            ("PostToolUseFailure", .errorExit),
            ("PermissionRequest", .permissionRequest),
            ("Notification", .permissionRequest),
            ("PermissionDenied", .errorExit),
            ("Stop", .stop),
            ("StopFailure", .errorExit),
        ]
        for (name, kind) in expected {
            let event = normalize(#"{"hook_event_name":"\#(name)","session_id":"S"}"#, arrival: now)
            #expect(event?.kind == kind, "\(name) should map to \(kind)")
        }
        // Unknown event name → unknown (no false done/waiting claim).
        #expect(normalize(#"{"hook_event_name":"Nonsense","session_id":"S"}"#, arrival: now)?.kind == .unknown)
    }

    // MARK: - TC-INT-322: PreToolUse + test-runner command → TEST_RUN_START

    @Test("TC-INT-322: PreToolUse Bash command running a known test runner → testRunStart")
    func preToolUseTestCommandIsTestRunStart() {
        let now = date("2026-06-16T12:00:00Z")
        for runner in ["pytest -q", "npx jest", "vitest run", "cargo test", "go test ./...", "npm test"] {
            let json = """
            {"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash",\
            "tool_input":{"command":"\(runner)"}}
            """
            #expect(normalize(json, arrival: now)?.kind == .testRunStart, "\(runner) should be a test run")
        }
        // A non-test Bash command stays a plain tool-use, not a test run.
        let plain = #"{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Bash","tool_input":{"command":"ls -la"}}"#
        #expect(normalize(plain, arrival: now)?.kind == .toolUse)
        // A test-runner string in a NON-Bash tool is not promoted.
        let nonBash = #"{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Edit","tool_input":{"command":"pytest"}}"#
        #expect(normalize(nonBash, arrival: now)?.kind == .toolUse)
    }

    // MARK: - TC-INT-323: missing timestamp → arrival-time stamp

    @Test("TC-INT-323: a hook with no timestamp is stamped with its arrival time")
    func missingTimestampStampsArrival() {
        let arrival = date("2026-06-16T12:00:00Z")
        let event = normalize(#"{"hook_event_name":"Stop","session_id":"S"}"#, arrival: arrival)
        #expect(event?.timestamp == arrival)
        // Staleness then measures silence from arrival: still inside the threshold,
        // not yet stale; past it, swept off running.
        let store = HookSessionStore(staleThreshold: 30)
        // Use a running signal stamped at arrival.
        let running = normalize(#"{"hook_event_name":"PreToolUse","session_id":"S"}"#, arrival: arrival)!
        store.ingest([running])
        store.sweepStale(now: arrival.addingTimeInterval(10))
        #expect(store.entry(for: "S")?.state == .running)
        // The sweep lands an unreported running session in explicit unknown; what this
        // case pins is the 30s arrival-relative edge.
        store.sweepStale(now: arrival.addingTimeInterval(31))
        #expect(store.entry(for: "S")?.state == .unknown)
    }

    // MARK: - TC-INT-324: reconciler precedence parity vs frozen Python oracle

    /// Parity against the frozen detector oracle. Unknown stays explicit: silence or
    /// unrecognized hooks must not be guessed into attention.
    @Test("TC-INT-324: reconciled transition path + final state match the frozen Python detector")
    func reconcilerParityWithFrozenPythonOracle() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hook-parity", isDirectory: true)
        let oracle = try OracleDetector.load(fixtures.appendingPathComponent("oracle-detector.json"))

        for scenario in oracle {
            let store = HookSessionStore(staleThreshold: 30)
            store.ingest(loadScenario(scenario.fixture, in: fixtures))
            if let sweep = scenario.sweepAt { store.sweepStale(now: sweep) }
            let path = store.transitions(for: scenario.sessionID).map(\.rawValue)
            #expect(path == scenario.transitions, "transition path drift in \(scenario.fixture)")
            #expect(store.entry(for: scenario.sessionID)?.state.rawValue == scenario.finalState,
                    "final-state drift in \(scenario.fixture)")
        }
    }

    /// Load a recorded fixture, routing each line to its source-specific normalizer
    /// (a `"source":"jsonl"` line goes through the JSONL fallback), mirroring the
    /// Python oracle's `_normalize`.
    private func loadScenario(_ name: String, in dir: URL) -> [SignalEvent] {
        let arrival = date("2000-01-01T00:00:00Z")  // unused: every fixture line carries a timestamp
        let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let data = Data(line.utf8)
            if isJSONL(data) { return JSONLNormalizer.normalize(data, arrival: arrival) }
            return HookNormalizer.normalize(data, arrival: arrival)
        }
    }

    private func isJSONL(_ data: Data) -> Bool {
        let object = try? JSONSerialization.jsonObject(with: data)
        return (object as? [String: Any])?["source"] as? String == "jsonl"
    }

    // MARK: - TC-INT-325: ambiguous signal → unknown (no false claim)

    @Test("TC-INT-325: an unclassifiable signal yields unknown, never a guessed done/waiting")
    func ambiguousSignalIsUnknown() {
        let now = date("2026-06-16T12:00:00Z")
        let store = HookSessionStore()
        // An event whose name is not in the map normalizes to `unknown`, and the
        // classifier maps `unknown` → unknown — never a false terminal claim.
        let event = normalize(#"{"hook_event_name":"WhoKnows","session_id":"S","timestamp":"2026-06-16T12:00:00+00:00"}"#, arrival: now)!
        #expect(event.kind == .unknown)
        store.ingest([event])
        let state = store.entry(for: "S")?.state
        #expect(state == .unknown)
        #expect(state != .done)
        #expect(state != .waitingForInput)
    }

    // MARK: - TC-INT-326: silent past threshold → swept to unknown

    @Test("TC-INT-326: a session silent past the stale threshold is swept off running, not left running")
    func silentPastThresholdSweptOffRunning() {
        let store = HookSessionStore(staleThreshold: 30)
        let start = date("2026-06-16T12:00:00Z")
        let running = SignalEvent(kind: .toolUse, source: .hook, sessionID: "S", timestamp: start, cwd: "/repo")
        store.ingest([running])
        #expect(store.entry(for: "S")?.state == .running)

        // Within threshold: still running.
        store.sweepStale(now: start.addingTimeInterval(10))
        #expect(store.entry(for: "S")?.state == .running)
        // Past threshold: explicit unknown, never a false attention or done claim.
        store.sweepStale(now: start.addingTimeInterval(31))
        let final = store.entry(for: "S")?.state
        #expect(final == .unknown)
        #expect(final != .done)
        // The project dir established earlier survives the state-only sweep.
        #expect(store.entry(for: "S")?.projectDir == "/repo")
    }

    @Test("TC-INT-326 guard: a terminal (done) session is never swept to unknown")
    func terminalSessionNotSwept() {
        let store = HookSessionStore(staleThreshold: 30)
        let start = date("2026-06-16T12:00:00Z")
        // SessionEnd is the real terminal signal (the session closed); Stop is only a
        // turn boundary. A closed session stays done through any later sweep.
        store.ingest([SignalEvent(kind: .sessionEnd, source: .hook, sessionID: "S", timestamp: start)])
        store.sweepStale(now: start.addingTimeInterval(120))
        #expect(store.entry(for: "S")?.state == .done)
    }

    @Test("TC-INT-326 guard: an idle (Stop) session is never swept to unknown")
    func idleSessionNotSwept() {
        let store = HookSessionStore(staleThreshold: 30)
        let start = date("2026-06-16T12:00:00Z")
        store.ingest([SignalEvent(kind: .stop, source: .hook, sessionID: "S", timestamp: start)])
        store.sweepStale(now: start.addingTimeInterval(120))
        #expect(store.entry(for: "S")?.state == .idle)
    }

    // MARK: - TC-INT-327: dropped / raced hooks reconcile correctly

    @Test("TC-INT-327: a dropped Stop hook is recovered by a lower-precedence JSONL turn-completed → idle")
    func droppedStopReconciledViaJSONL() {
        let store = HookSessionStore()
        let start = date("2026-06-16T12:00:00Z")
        let events = [
            SignalEvent(kind: .sessionStart, source: .hook, sessionID: "S", timestamp: start),
            SignalEvent(kind: .toolUse, source: .hook, sessionID: "S", timestamp: start.addingTimeInterval(5)),
            // Stop hook never arrives; the JSONL fallback closes the turn.
            SignalEvent(kind: .stop, source: .jsonl, sessionID: "S", timestamp: start.addingTimeInterval(12)),
        ]
        store.ingest(events)
        let final = store.entry(for: "S")?.state
        // The recovered turn-end clears running; it does NOT stay stuck in running and
        // does NOT claim attention without a notification.
        #expect(final == .idle)
        #expect(final != .running)
        #expect(store.transitions(for: "S").contains(.blocked) == false)
    }

    @Test("TC-INT-327: a higher-precedence hook wins over a same-burst lower-precedence signal")
    func hookPrecedenceWinsInBurst() {
        let store = HookSessionStore(coalesceWindow: 1)
        let start = date("2026-06-16T12:00:00Z")
        // Same sub-second burst: a PTY-sourced stop and a hook-sourced tool-use.
        // The hook (rank 3) dominates → running, not done.
        let events = [
            SignalEvent(kind: .stop, source: .pty, sessionID: "S", timestamp: start.addingTimeInterval(0.1)),
            SignalEvent(kind: .toolUse, source: .hook, sessionID: "S", timestamp: start.addingTimeInterval(0.2)),
        ]
        store.ingest(events)
        #expect(store.entry(for: "S")?.state == .running)
    }

    // MARK: - TC-UNIT-321: tail resumes from persisted offset; no reprocess on relaunch

    @Test("TC-UNIT-321: the tail resumes from its persisted offset — no reprocessing on relaunch")
    func tailResumesFromOffsetNoReprocess() throws {
        let file = makeEventsFile()
        let offset = file.appendingPathExtension("offset")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: offset)
        }
        try append("line-1", to: file)
        try append("line-2", to: file)

        // First tail drains both lines and persists the offset.
        let first = HookEventTail(file: file, offsetStore: offset)
        #expect(first.poll().map { String(decoding: $0, as: UTF8.self) } == ["line-1", "line-2"])

        // A fresh tail (app relaunch) sees nothing new — no reprocessing.
        let relaunched = HookEventTail(file: file, offsetStore: offset)
        #expect(relaunched.poll().isEmpty)

        // A new append after relaunch is the only thing drained.
        try append("line-3", to: file)
        #expect(relaunched.poll().map { String(decoding: $0, as: UTF8.self) } == ["line-3"])
    }

    // MARK: - TC-UNIT-322: offset > size (rotation/truncation) → reset to 0

    @Test("TC-UNIT-322: an offset past EOF (rotation/truncation) resets to 0 and re-reads the tail")
    func offsetPastEOFResetsToZero() throws {
        let file = makeEventsFile()
        let offset = file.appendingPathExtension("offset")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: offset)
        }
        try append("old-1", to: file)
        try append("old-2", to: file)
        let tail = HookEventTail(file: file, offsetStore: offset)
        _ = tail.poll()  // advance the offset past the end

        // The file is rotated/truncated to a smaller content (offset now past EOF).
        try Data("fresh\n".utf8).write(to: file)
        // No crash; resets to 0 and reads the new content from the top.
        #expect(tail.poll().map { String(decoding: $0, as: UTF8.self) } == ["fresh"])
    }

    // MARK: - TC-UNIT-323: partial trailing line not consumed until newline arrives

    @Test("TC-UNIT-323: a partial (newline-less) trailing line is held until its newline arrives")
    func partialTrailingLineWaitsForNewline() throws {
        let file = makeEventsFile()
        let offset = file.appendingPathExtension("offset")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: offset)
        }
        // A whole line plus a half-written one (no trailing newline yet).
        try Data("complete\npartial".utf8).write(to: file)
        let tail = HookEventTail(file: file, offsetStore: offset)
        #expect(tail.poll().map { String(decoding: $0, as: UTF8.self) } == ["complete"])

        // The writer finishes the partial line; only now is it consumed (intact).
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("-rest\n".utf8))
        try handle.close()
        #expect(tail.poll().map { String(decoding: $0, as: UTF8.self) } == ["partial-rest"])
    }

    // MARK: - Non-JSON line skipped, not fatal (US-003 edge 4)

    @Test("TC-UNIT-323 guard: a non-JSON line normalizes to nil (skipped, not fatal)")
    func nonJSONLineSkipped() {
        let now = date("2026-06-16T12:00:00Z")
        #expect(normalize("not json at all", arrival: now) == nil)
        #expect(normalize("", arrival: now) == nil)
        // A valid JSON line after a garbage one still normalizes.
        #expect(normalize(#"{"hook_event_name":"Stop","session_id":"S"}"#, arrival: now)?.kind == .stop)
    }
}

// MARK: - Frozen-oracle decoding (Python detector JSON)

/// One scenario from the frozen Python detector oracle: the recorded fixture, the
/// session it drives, the emitted transition path, the final state, and an optional
/// sweep `now` (to exercise staleness-to-unknown).
private struct OracleScenario {
    let fixture: String
    let sessionID: String
    let transitions: [String]
    let finalState: String
    let sweepAt: Date?
}

private enum OracleDetector {
    private struct Raw: Decodable {
        let sessionId: String
        let transitions: [String]
        let finalState: String
    }
    private struct Envelope: Decodable { let scenarios: [Raw] }

    /// The fixture filename + sweep time per scenario, keyed by session id. These
    /// scenarios match the frozen `oracle-detector.json` committed beside the
    /// fixtures — the parity oracle is now a static artifact (its Python generator
    /// was retired in the Phase-03 cutover; the fixture is the source of truth).
    private static let meta: [String: (fixture: String, sweep: String?)] = [
        "sess-normal": ("normal_turn.jsonl", nil),
        "sess-dropped": ("dropped_stop.jsonl", nil),
        "sess-rapid": ("rapid_transitions.jsonl", nil),
        "sess-silent": ("silent_after_running.jsonl", "2026-06-16T12:00:34+00:00"),
    ]

    static func load(_ url: URL) throws -> [OracleScenario] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: url))
        return envelope.scenarios.map { raw in
            let m = meta[raw.sessionId]!
            return OracleScenario(
                fixture: m.fixture,
                sessionID: raw.sessionId,
                transitions: raw.transitions,
                finalState: raw.finalState,
                sweepAt: m.sweep.flatMap { ISO8601DateFormatter().date(from: $0) }
            )
        }
    }
}
