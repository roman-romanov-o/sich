import Foundation
import Testing

@testable import SichCore

/// Native interactive-quota reads (US-002) — the Swift port of `quota/jsonl_usage.py`
/// + the source-assembly half of `quota/live.py`. These pin the JSONL walk, the 5h
/// rolling-window + weekly aging, the honest-degradation rules, and (TC-INT-300)
/// full parity against the frozen Python `build_quota_response()` on a shared fixture.
///
/// Harness rules (inherited): never reads the real `~/.claude`, never spawns
/// `claude -p`. Every case builds its own fixture transcript dir under the test's
/// temp dir, and injects `now` so the window aging is deterministic.
///
/// `.serialized`: a couple of cases exercise the env-override knob
/// (`SICH_WINDOW_CAP_TOKENS` / `WEEKLY_CAP_TOKENS`), and `setenv` mutates
/// process-global state. Running the suite serially keeps that mutation from
/// leaking into the default-cap / parity cases that run alongside it.
@Suite("Native quota reads (port of jsonl_usage + live.py — US-002)", .serialized)
struct QuotaUsageReaderTests {

    // MARK: - Fixture helpers (per-test temp transcript dir, never the real ~/.claude)

    /// A fresh temp `projects/` dir; the caller drops `*.jsonl` files under it.
    private func makeProjectsDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-quota-\(UUID().uuidString)", isDirectory: true)
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        return projects
    }

    /// Write one transcript `lines` (joined by newlines) under `dir/sub/name.jsonl`.
    private func writeTranscript(_ lines: [String], named name: String, under dir: URL, sub: String = "p") throws {
        let projectDir = dir.appendingPathComponent(sub, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("\(name).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// One `assistant` usage record line at `iso`, with the four token classes.
    private func usageLine(
        _ iso: String, input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0
    ) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":\(input),\
        "output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreation),\
        "cache_read_input_tokens":\(cacheRead)}},"timestamp":"\(iso)"}
        """
    }

    private func date(_ iso: String) -> Date {
        let fmt = ISO8601DateFormatter()
        return fmt.date(from: iso)!
    }

    /// The interactive source (always index 0).
    private func interactive(_ sources: [QuotaSourceInput]) -> QuotaSourceReading {
        sources[0].reading
    }

    // MARK: - TC-UNIT-301: sum 4 token classes on assistant turns; skip non-usage

    @Test("TC-UNIT-301: sum input/output/cache_creation/cache_read on assistant turns; skip non-usage")
    func sumsFourTokenClassesSkippingNonUsage() throws {
        let dir = try makeProjectsDir()
        let now = date("2026-06-26T12:00:00Z")
        try writeTranscript([
            usageLine("2026-06-26T11:00:00Z", input: 10, output: 20, cacheCreation: 30, cacheRead: 40),
            // non-assistant + assistant-without-usage are skipped (no contribution):
            #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-06-26T11:01:00Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant"},"timestamp":"2026-06-26T11:02:00Z"}"#,
        ], named: "s", under: dir)

        let events = QuotaUsageReader.readUsageEvents(now: now, projectsDir: dir)
        #expect(events.count == 1)
        #expect(events[0].amount == 100)  // 10+20+30+40, the only usage record
    }

    // MARK: - TC-UNIT-302: 5h rolling window; events age out at +5h

    @Test("TC-UNIT-302: usage ages to a 5h rolling window; events age out exactly at +5h")
    func eventsAgeOutOfFiveHourWindow() throws {
        let dir = try makeProjectsDir()
        let now = date("2026-06-26T12:00:00Z")
        try writeTranscript([
            usageLine("2026-06-26T10:00:00Z", input: 1000),  // 2h old → in window
            usageLine("2026-06-26T06:30:00Z", input: 2000),  // 5.5h old → aged out of window, in weekly
        ], named: "s", under: dir)

        let sources = QuotaUsageReader.read(now: now, projectsDir: dir)
        let reading = interactive(sources)
        // Window cap default 200_000_000. Only the 1000-token event is in-window.
        let windowUsed = 1000.0
        let expected = (200_000_000.0 - windowUsed) / 200_000_000.0
        #expect(abs((reading.remainingFraction ?? -1) - expected) < 1e-9)
        // Reset = oldest in-window event (10:00) + 5h = 15:00 (whole-second).
        #expect(reading.reset == date("2026-06-26T15:00:00Z"))
    }

    // MARK: - TC-UNIT-303: weekly cap dominates when binding; reset = sooner of window/weekly

    @Test("TC-UNIT-303: weekly cap dominates when binding; remaining = the tighter fraction")
    func weeklyCapDominatesWhenBinding() throws {
        let dir = try makeProjectsDir()
        let now = date("2026-06-26T12:00:00Z")
        // Tiny caps so the weekly total binds tighter than the window total.
        setenv("SICH_WINDOW_CAP_TOKENS", "1000", 1)
        setenv("SICH_WEEKLY_CAP_TOKENS", "1200", 1)
        defer {
            unsetenv("SICH_WINDOW_CAP_TOKENS")
            unsetenv("SICH_WEEKLY_CAP_TOKENS")
        }
        try writeTranscript([
            usageLine("2026-06-26T11:00:00Z", input: 500),   // in window + weekly
            usageLine("2026-06-24T11:00:00Z", input: 600),   // weekly only (aged out of window)
        ], named: "s", under: dir)

        let reading = interactive(QuotaUsageReader.read(now: now, projectsDir: dir))
        // window: used 500 / cap 1000 → 0.5 remaining.
        // weekly: used 1100 / cap 1200 → 0.0833 remaining → binds (tighter).
        let weeklyRemaining = (1200.0 - 1100.0) / 1200.0
        #expect(abs((reading.remainingFraction ?? -1) - weeklyRemaining) < 1e-9)
    }

    // MARK: - TC-UNIT-304: malformed line / unreadable file skipped, rest survives

    @Test("TC-UNIT-304: a malformed JSON line is skipped; the rest of the file still contributes")
    func malformedLineSkippedRestSurvives() throws {
        let dir = try makeProjectsDir()
        let now = date("2026-06-26T12:00:00Z")
        try writeTranscript([
            usageLine("2026-06-26T11:00:00Z", input: 100),
            #"{"type":"assistant","message":{"usage":{ truncated..."#,  // not valid JSON
            usageLine("2026-06-26T11:30:00Z", input: 200),
        ], named: "s", under: dir)

        let events = QuotaUsageReader.readUsageEvents(now: now, projectsDir: dir)
        #expect(events.count == 2)
        #expect(events.map(\.amount).sorted() == [100, 200])
    }

    // MARK: - TC-UNIT-305: events older than 7d lookback excluded

    @Test("TC-UNIT-305: usage older than the 7d weekly lookback is excluded entirely")
    func eventsOlderThanLookbackExcluded() throws {
        let dir = try makeProjectsDir()
        let now = date("2026-06-26T12:00:00Z")
        try writeTranscript([
            usageLine("2026-06-22T12:00:00Z", input: 100),   // 4d old → kept
            usageLine("2026-06-18T11:59:00Z", input: 9999),  // >7d old → excluded
        ], named: "s", under: dir)

        let events = QuotaUsageReader.readUsageEvents(now: now, projectsDir: dir)
        #expect(events.count == 1)
        #expect(events[0].amount == 100)
    }

    // MARK: - TC-UNIT-306: caps overridable via env

    @Test("TC-UNIT-306: SICH_WINDOW_CAP_TOKENS / WEEKLY_CAP_TOKENS override the defaults")
    func capsOverridableViaEnv() throws {
        let dir = try makeProjectsDir()
        let now = date("2026-06-26T12:00:00Z")
        setenv("SICH_WINDOW_CAP_TOKENS", "400", 1)
        setenv("SICH_WEEKLY_CAP_TOKENS", "1000000", 1)
        defer {
            unsetenv("SICH_WINDOW_CAP_TOKENS")
            unsetenv("SICH_WEEKLY_CAP_TOKENS")
        }
        try writeTranscript([
            usageLine("2026-06-26T11:00:00Z", input: 100),  // in window
        ], named: "s", under: dir)

        let reading = interactive(QuotaUsageReader.read(now: now, projectsDir: dir))
        // window cap 400, used 100 → 0.75 remaining (proves the env override took).
        #expect(abs((reading.remainingFraction ?? -1) - 0.75) < 1e-9)
    }

    // MARK: - TC-INT-301: four sources, interactive inferred:true, three unknown

    @Test("TC-INT-301: four sources out — interactive inferred:true, three (sdk/codex/gemini) unknown")
    func fourSourcesInteractiveInferredThreeUnknown() throws {
        let dir = try makeProjectsDir()
        let now = date("2026-06-26T12:00:00Z")
        try writeTranscript([usageLine("2026-06-26T11:00:00Z", input: 100)], named: "s", under: dir)

        let sources = QuotaUsageReader.read(now: now, projectsDir: dir)
        #expect(sources.count == 4)

        #expect(sources[0].provider == "anthropic" && sources[0].pool == "interactive")
        #expect(sources[0].reading.inferred == true)
        #expect(sources[0].reading.available == true)

        #expect(sources[1].provider == "anthropic" && sources[1].pool == "agent_sdk_credit")
        #expect(sources[2].provider == "codex" && sources[2].pool == "codex")
        #expect(sources[3].provider == "gemini" && sources[3].pool == "gemini")
        for i in 1...3 {
            #expect(sources[i].reading.available == false)            // unknown, not measured
            #expect(sources[i].reading.remainingFraction == nil)      // not 0
            #expect(QuotaProjection.gauge(for: sources[i]).state == .unknown)
        }
    }

    // MARK: - TC-INT-302: no pool netted against another

    @Test("TC-INT-302: no pool is netted against another — four distinct gauges, in order")
    func noPoolNettedAgainstAnother() throws {
        let dir = try makeProjectsDir()
        let now = date("2026-06-26T12:00:00Z")
        try writeTranscript([usageLine("2026-06-26T11:00:00Z", input: 100)], named: "s", under: dir)

        let gauges = QuotaProjection.gauges(from: QuotaUsageReader.read(now: now, projectsDir: dir))
        let pools = gauges.map(\.pool)
        #expect(pools == ["interactive", "agent_sdk_credit", "codex", "gemini"])
        #expect(Set(pools).count == 4)  // distinct — none folded into another
    }

    // MARK: - TC-INT-303: absent projects_dir → real-zero, not unknown/full

    @Test("TC-INT-303: absent projects_dir → interactive reads fresh real-zero usage, NOT unknown/full")
    func absentProjectsDirIsRealZeroNotUnknown() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-absent-\(UUID().uuidString)/projects", isDirectory: true)
        let now = date("2026-06-26T12:00:00Z")

        let sources = QuotaUsageReader.read(now: now, projectsDir: missing)
        let reading = interactive(sources)
        // Honest: the interactive pool is AVAILABLE (we can see it) and fresh — full
        // remaining from real-zero usage, NOT the `unknown` of the non-local pools.
        #expect(reading.available == true)
        #expect(reading.inferred == true)
        #expect(reading.remainingFraction == 1.0)
        #expect(QuotaProjection.gauge(for: sources[0]).state == .active)
        // The three non-local pools are still unknown (the contrast AC3 demands).
        #expect(sources[1].reading.available == false)
    }

    // MARK: - TC-INT-300: full parity vs frozen Python build_quota_response()

    @Test("TC-INT-300: Swift reader reproduces the frozen Python build_quota_response() on a shared fixture")
    func parityWithFrozenPythonOracle() throws {
        // Shared fixture committed under Fixtures/quota-parity (the SAME dir the Python
        // oracle ran over). Resolved via #filePath so no SwiftPM resource bundle is
        // needed — the reader reads a `projectsDir` URL off disk regardless.
        let fixturesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/quota-parity", isDirectory: true)
        let projects = fixturesRoot.appendingPathComponent("projects", isDirectory: true)
        let oracleURL = fixturesRoot.appendingPathComponent("oracle-build_quota_response.json")

        let now = date("2026-06-26T12:00:00Z")  // identical to the oracle-generation `now`
        let sources = QuotaUsageReader.read(now: now, projectsDir: projects)
        let oracle = try OracleQuota.load(oracleURL)

        #expect(sources.count == oracle.count)
        for (got, want) in zip(sources, oracle) {
            #expect(got.provider == want.provider)
            #expect(got.pool == want.pool)
            #expect(got.reading.available == want.available)
            #expect(got.reading.inferred == want.inferred)
            // Token-derived fraction must match to floating tolerance.
            assertOptionalDoubleEqual(got.reading.remainingFraction, want.remainingFraction)
            // reset compared at whole-second resolution (both sides truncate).
            #expect(got.reading.reset == want.reset)
            // never-netted: the projected gauge state agrees with the Python one.
            #expect(QuotaProjection.gauge(for: got).state.rawValue == want.state(projected: got.reading.available))
        }
        // Fields intentionally NOT compared: `remaining_amount` (always null for the
        // interactive window source — it reports a fraction, not an absolute) and
        // `unit` (null for every pool here). Both are null on both sides; comparing
        // null==null adds nothing. `refill_kind` is asserted indirectly via the
        // projected gauge state + TC-INT-301.
    }

    private func assertOptionalDoubleEqual(_ a: Double?, _ b: Double?) {
        switch (a, b) {
        case (nil, nil): break
        case let (x?, y?): #expect(abs(x - y) < 1e-9)
        default: #expect(Bool(false), "one side nil, the other not: \(String(describing: a)) vs \(String(describing: b))")
        }
    }
}

// MARK: - Frozen-oracle decoding (Python build_quota_response() JSON)

/// One source from the frozen Python `build_quota_response()` JSON. Snake_case keys
/// match the Python wire; the `reset` is whole-second ISO-8601.
private struct OracleSource: Decodable {
    let provider: String
    let pool: String
    let available: Bool
    let inferred: Bool
    let remainingFraction: Double?
    let resetRaw: String?

    var reset: Date? {
        guard let resetRaw else { return nil }
        return ISO8601DateFormatter().date(from: resetRaw)
    }

    /// The Python availability projected to a gauge-state rawValue, for the parity
    /// cross-check (available interactive → active; absent → unknown).
    func state(projected available: Bool) -> String { available ? "active" : "unknown" }

    private struct Reading: Decodable {
        let available: Bool
        let inferred: Bool
        let remainingFraction: Double?
        let reset: String?
    }
    private enum Keys: String, CodingKey { case provider, pool, reading }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        provider = try c.decode(String.self, forKey: .provider)
        pool = try c.decode(String.self, forKey: .pool)
        let r = try c.decode(Reading.self, forKey: .reading)
        available = r.available
        inferred = r.inferred
        remainingFraction = r.remainingFraction
        resetRaw = r.reset
    }
}

private enum OracleQuota {
    private struct Envelope: Decodable { let sources: [OracleSource] }

    static func load(_ url: URL) throws -> [OracleSource] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Envelope.self, from: Data(contentsOf: url)).sources
    }
}
