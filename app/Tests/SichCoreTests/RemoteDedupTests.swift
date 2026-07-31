import CryptoKit
import Foundation
import Testing

@testable import SichCore

/// ts-unit-02 — the dedup keys for both line kinds (TC-UNIT-008..011).
///
/// A reconnect re-runs `tail -n 200 -F`, so the same bytes come back. What must not
/// come back is a card that moved backwards or a diff that landed twice. Both keys
/// are asserted here against the two look-alike implementations that would pass a
/// naive test and fail in production: a byte cursor, and a key computed on the
/// NORMALIZED value.
@Suite("Remote dedup keys (ts-unit-02)")
struct RemoteDedupTests {

    // MARK: - US-008 AC-3: state hooks key on the RAW line bytes

    @Test("TC-UNIT-008: identical raw bytes are admitted once; one byte apart is two lines")
    func stateHookKeysOnRawLineBytes() {
        var window = DedupWindow(capacity: 8)
        let line = Data(#"{"hook_event_name":"Stop","session_id":"abc"}"#.utf8)

        // `admit` is mutating, and `#expect` autocloses its receiver — so each verdict
        // is taken first and asserted after.
        let first = window.admit(line)
        let replay = window.admit(line)
        let oneByteApart = window.admit(Data(#"{"hook_event_name":"Stop","session_id":"abd"}"#.utf8))

        #expect(first)
        #expect(replay == false, "the same bytes are a replay, not news")
        #expect(oneByteApart, "one byte apart is a different fact")
    }

    @Test("TC-UNIT-008 / AC-3: the key is (host, sha256(line)) — two hosts never eat each other's lines")
    func theKeyIsHostQualified() throws {
        let line = #"{"hook_event_name":"Stop","session_id":"abc"}"#
        let alpha = try relayParts(host: "alpha.invalid")
        let beta = try relayParts(host: "beta.invalid")
        defer { alpha.relay.stop(); beta.relay.stop() }

        alpha.transport.emit([line])
        beta.transport.emit([line])

        #expect(alpha.lines.count == 1)
        #expect(beta.lines.count == 1, "a byte-identical line from another host is a different fact")
        #expect(alpha.lines.all.map(\.host) == ["alpha.invalid"])
        #expect(beta.lines.all.map(\.host) == ["beta.invalid"])
    }

    /// The byte-cursor look-alike. `tail -n 200 -F` reopens with no memory of where it
    /// stopped, and the far side may have rotated the file underneath — so the replay
    /// after a reconnect starts at a DIFFERENT offset for the same content. A cursor
    /// would either re-ingest everything (offset reset) or skip live lines (offset kept).
    @Test("TC-UNIT-008 / AC-3: a replay at a different offset is still deduped (never a byte cursor)")
    func aReplayAtADifferentOffsetIsDeduped() throws {
        let far = try relayParts(host: "far.invalid")
        defer { far.relay.stop() }

        far.transport.emit((1...5).map { #"{"hook_event_name":"Stop","n":\#($0)}"# })
        #expect(far.lines.count == 5)

        // The remote log rotated: the same five lines now sit at completely different
        // byte offsets, and three new ones follow them.
        far.transport.emit((1...8).map { #"{"hook_event_name":"Stop","n":\#($0)}"# })
        #expect(far.lines.count == 8, "the seen prefix is suppressed, the unseen suffix is ingested")
    }

    /// The normalized-value look-alike. A hook line without a `timestamp` normalizes to
    /// the ARRIVAL time, so the very same bytes replayed a minute later produce a
    /// SignalEvent that is not equal to the first one — keying on that admits the replay.
    @Test("TC-UNIT-008 / AC-3: a timestamp-less line replayed later is deduped (hash BEFORE normalization)")
    func aTimestampLessReplayIsDeduped() throws {
        let raw = #"{"hook_event_name":"Stop","session_id":"abc","cwd":"/repo"}"#
        let first = HookNormalizer.normalize(Data(raw.utf8), arrival: Date(timeIntervalSince1970: 1_000))
        let later = HookNormalizer.normalize(Data(raw.utf8), arrival: Date(timeIntervalSince1970: 1_060))
        #expect(first != later, "the normalized values differ — which is why the key is not one")
        #expect(first?.timestamp != later?.timestamp)

        let far = try relayParts(host: "far.invalid")
        defer { far.relay.stop() }
        far.transport.emit([raw])
        far.transport.emit([raw])
        #expect(far.lines.count == 1, "byte-identical bytes are one line however late they arrive")
    }

    @Test("AC-3 edge: the dedup memory is bounded over many reconnects")
    func theDedupMemoryIsBounded() {
        var window = DedupWindow(capacity: 4)
        for n in 0..<400 { _ = window.admit(Data("{\"n\":\(n)}".utf8)) }
        #expect(window.count == 4)
    }

    // MARK: - US-008 AC-2: a turn diff keys on FOUR parts

    @Test("TC-UNIT-009 / AC-2: two Stops in one iteration are two turns, not one")
    func twoStopsInOneIterationAreTwoDistinctKeys() {
        // `iteration` increments on UserPromptSubmit only; `turn_diff` fires on every
        // Stop and merely READS it, against a checkpoint that is never cleared. One
        // turn, two Stops, two different diffs, one iteration number.
        let first = turnDiff(iteration: 3, body: "--- a/x\n+++ b/x\n@@\n+one\n")
        let second = turnDiff(iteration: 3, body: "--- a/x\n+++ b/x\n@@\n+one\n+two\n")

        #expect(TurnDiffKey(first) != TurnDiffKey(second),
                "keyed on (host, session, iteration) alone the second diff is eaten")
        #expect(TurnDiffKey(first) == TurnDiffKey(first))
    }

    @Test("TC-UNIT-009 / AC-2: the key is host- and session-qualified")
    func theDiffKeyIsHostAndSessionQualified() {
        let body = "--- a/x\n+++ b/x\n@@\n+same\n"
        let base = turnDiff(iteration: 1, body: body, host: "alpha.invalid")

        #expect(TurnDiffKey(base) != TurnDiffKey(turnDiff(iteration: 1, body: body, host: "beta.invalid")))
        #expect(TurnDiffKey(base) != TurnDiffKey(turnDiff(iteration: 1, body: body, host: nil)))
        #expect(TurnDiffKey(base) != TurnDiffKey(
            turnDiff(iteration: 1, body: body, host: "alpha.invalid", sessionID: "other")))
        #expect(TurnDiffKey(base) != TurnDiffKey(turnDiff(iteration: 2, body: body, host: "alpha.invalid")))
    }

    /// The replayed line is the SAME bytes, but the forwarder stamps whole seconds and
    /// a stamp-less line falls back to arrival — so a key that touched `timestamp` (or
    /// the volatile `cwd`) would call the replay news.
    @Test("TC-UNIT-010 / AC-2: the key ignores timestamp and cwd")
    func theDiffKeyIgnoresTimestampAndCwd() {
        let body = "--- a/x\n+++ b/x\n@@\n+same\n"
        let live = TurnDiff(
            sessionID: "s", cwd: "/srv/app", iteration: 4,
            timestamp: Date(timeIntervalSince1970: 1_000), unifiedDiff: body, host: "far.invalid")
        let replayed = TurnDiff(
            sessionID: "s", cwd: "/tmp/checkout", iteration: 4,
            timestamp: Date(timeIntervalSince1970: 9_999), unifiedDiff: body, host: "far.invalid")

        #expect(live != replayed, "the values differ — which is why the key is not one")
        #expect(TurnDiffKey(live) == TurnDiffKey(replayed))
    }

    // MARK: - Fixtures

    private func turnDiff(
        iteration: Int, body: String, host: String? = "far.invalid", sessionID: String = "s"
    ) -> TurnDiff {
        TurnDiff(
            sessionID: sessionID, iteration: iteration,
            timestamp: Date(timeIntervalSince1970: 1_000), unifiedDiff: body, host: host)
    }

    private struct RelayParts {
        let relay: RemoteEventRelay
        let transport: ScriptedTransport
        let lines: LineCollector
    }

    /// A started relay wired to a scripted transport — no test dials a host, and the
    /// reconnect delay is parked far beyond any test's lifetime.
    private func relayParts(host: String) throws -> RelayParts {
        let transport = ScriptedTransport()
        let lines = LineCollector()
        let relay = try RemoteEventRelay(
            spec: RemoteTmuxSpec(host: host), transport: transport,
            reconnectDelay: 3_600, sink: { lines.add($0) })
        relay.start()
        return RelayParts(relay: relay, transport: transport, lines: lines)
    }
}
