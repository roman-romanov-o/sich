import Foundation
import Testing

@testable import GhostlingCore

/// The on-disk Codex rate-limit reader behind the measured codex gauge. Pure
/// file reads against per-test fixture trees — no spawn, no network, no real
/// `~/.codex`. The fixture line is byte-shaped like a real rollout `token_count`
/// event (codex CLI, 2026-07 capture).
@Suite("Codex rollout telemetry parse + codex source mapping")
struct CodexUsageReaderTests {

    /// Fixed `now`; resets are epoch seconds placed relative to it.
    private let now = Date(timeIntervalSince1970: 1_783_200_000)

    /// A real-shaped rollout line (extra fields intact — the parser must ignore them).
    private func rolloutLine(
        primaryUsed: Double = 88.0, primaryResets: Double = 1_783_256_844,
        secondaryUsed: Double = 30.0, secondaryResets: Double = 1_783_795_570
    ) -> String {
        """
        {"timestamp":"2026-07-05T11:19:38.101Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":3938883,"total_tokens":3962086}},\
        "rate_limits":{"limit_id":"codex","limit_name":null,\
        "primary":{"used_percent":\(primaryUsed),"window_minutes":300,"resets_at":\(primaryResets)},\
        "secondary":{"used_percent":\(secondaryUsed),"window_minutes":10080,"resets_at":\(secondaryResets)},\
        "credits":null,"individual_limit":null,"plan_type":"plus","rate_limit_reached_type":null}}}
        """
    }

    /// Build `<tmp>/sessions/2026/07/05/rollout-….jsonl` fixtures; mtimes are set
    /// explicitly so "newest file" ordering is deterministic.
    private func makeSessionsDir(files: [(name: String, lines: [String], mtime: Date)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString)/sessions/2026/07/05", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file.name)
            try file.lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: file.mtime], ofItemAtPath: url.path)
        }
        return root
    }

    @Test("real-shape line: primary binds (88 ≥ 30) → measured, 0.12 remaining, rolling window, epoch reset")
    func primaryBinds() throws {
        let dir = try makeSessionsDir(files: [
            ("rollout-a.jsonl", [rolloutLine()], now)
        ])
        let src = try #require(CodexUsageReader.source(now: now, sessionsDir: dir))
        #expect(src.provider == "codex")
        #expect(src.pool == "codex")
        #expect(src.reading.inferred == false)   // the CLI's own measurement → "measured"
        #expect(abs((src.reading.remainingFraction ?? -1) - 0.12) < 1e-9)
        #expect(src.reading.refillKind == .rollingWindow)
        #expect(src.reading.reset == Date(timeIntervalSince1970: 1_783_256_844))
        #expect(src.reading.state == .active)
    }

    @Test("secondary binds (10 < 55) → weekly, secondary reset")
    func secondaryBinds() throws {
        let dir = try makeSessionsDir(files: [
            ("rollout-a.jsonl", [rolloutLine(primaryUsed: 10, secondaryUsed: 55)], now)
        ])
        let src = try #require(CodexUsageReader.source(now: now, sessionsDir: dir))
        #expect(abs((src.reading.remainingFraction ?? -1) - 0.45) < 1e-9)
        #expect(src.reading.refillKind == .weekly)
        #expect(src.reading.reset == Date(timeIntervalSince1970: 1_783_795_570))
    }

    @Test("expired primary reads as 0% used → low secondary still binds")
    func expiredPrimaryYieldsToSecondary() throws {
        let past = now.timeIntervalSince1970 - 60
        let dir = try makeSessionsDir(files: [
            ("rollout-a.jsonl", [rolloutLine(primaryUsed: 88, primaryResets: past, secondaryUsed: 5)], now)
        ])
        let src = try #require(CodexUsageReader.source(now: now, sessionsDir: dir))
        #expect(abs((src.reading.remainingFraction ?? -1) - 0.95) < 1e-9)
        #expect(src.reading.refillKind == .weekly)
    }

    @Test("both windows expired → full remaining, nil reset (next reset unknowable)")
    func bothExpired() throws {
        let past = now.timeIntervalSince1970 - 60
        let dir = try makeSessionsDir(files: [
            ("rollout-a.jsonl",
             [rolloutLine(primaryUsed: 88, primaryResets: past, secondaryUsed: 30, secondaryResets: past)],
             now)
        ])
        let src = try #require(CodexUsageReader.source(now: now, sessionsDir: dir))
        #expect(src.reading.remainingFraction == 1.0)
        #expect(src.reading.reset == nil)
        #expect(src.reading.state == .active)
    }

    @Test("100% used → exhausted, remaining 0")
    func exhausted() throws {
        let dir = try makeSessionsDir(files: [
            ("rollout-a.jsonl", [rolloutLine(primaryUsed: 100)], now)
        ])
        let src = try #require(CodexUsageReader.source(now: now, sessionsDir: dir))
        #expect(src.reading.remainingFraction == 0.0)
        #expect(src.reading.state == .exhausted)
    }

    @Test("the LAST rate_limits line in the file wins, junk lines tolerated")
    func lastSnapshotWins() throws {
        let dir = try makeSessionsDir(files: [
            ("rollout-a.jsonl", [
                rolloutLine(primaryUsed: 20),
                #"{"type":"event_msg","payload":{"type":"agent_message","message":"rate_limits mentioned in chat"}}"#,
                "not json at all {{{",
                rolloutLine(primaryUsed: 88),
            ], now)
        ])
        let src = try #require(CodexUsageReader.source(now: now, sessionsDir: dir))
        #expect(abs((src.reading.remainingFraction ?? -1) - 0.12) < 1e-9)
    }

    @Test("newest rollout without a snapshot → falls back to the next-newest that has one")
    func fallsBackToOlderRollout() throws {
        let dir = try makeSessionsDir(files: [
            ("rollout-new.jsonl",
             [#"{"type":"session_meta","payload":{"id":"just-started"}}"#],
             now),
            ("rollout-old.jsonl", [rolloutLine(primaryUsed: 40)], now.addingTimeInterval(-3600)),
        ])
        let src = try #require(CodexUsageReader.source(now: now, sessionsDir: dir))
        #expect(abs((src.reading.remainingFraction ?? -1) - 0.60) < 1e-9)
    }

    @Test("no rollouts / absent dir → nil, the gauge stays unknown")
    func noTelemetryIsNil() throws {
        let empty = try makeSessionsDir(files: [])
        #expect(CodexUsageReader.source(now: now, sessionsDir: empty) == nil)
        let absent = empty.appendingPathComponent("does-not-exist")
        #expect(CodexUsageReader.source(now: now, sessionsDir: absent) == nil)
    }
}
