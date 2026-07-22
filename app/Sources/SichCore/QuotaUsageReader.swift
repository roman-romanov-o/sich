import Foundation

/// Native, in-process interactive-pool quota reads — the Swift port of
/// `quota/jsonl_usage.py` + the source-assembly half of `quota/live.py`.
///
/// `read(now:projectsDir:)` walks `~/.claude/projects/**/*.jsonl`, sums the token
/// usage on each `assistant` turn, ages the events to a 5h rolling window + a weekly
/// cap, and produces the SAME four `[QuotaSourceInput]` the existing `QuotaProjection`
/// already consumes — bypassing the `GET /quota` HTTP wire entirely (DD-001). The
/// projection math is NOT re-implemented here; only the *origin* of the readings
/// changes from "decode HTTP body" to "read disk".
///
/// Watcher-not-spawner: this only ever READS files — it never spawns `claude -p`,
/// binds no port, and starts no process. The interactive pool is the one locally
/// observable source; the three non-local pools (Agent-SDK credit, Codex, Gemini)
/// stay `unknown` — never 0, never 100% (the honest-degradation rule).

// MARK: - Usage event

/// A single assistant-turn usage spike charged against the rolling window — the
/// Swift mirror of `window_math.UsageEvent` (`at` at whole-second resolution so the
/// derived reset stays microsecond-free, matching the Python).
public struct UsageEvent: Sendable, Equatable {
    public let at: Date
    public let amount: Double

    public init(at: Date, amount: Double) {
        self.at = at
        self.amount = amount
    }
}

// MARK: - Reader

public enum QuotaUsageReader {

    // Calibration knobs — the 5h-window and weekly token caps the summed usage is
    // measured against. Anthropic does not publish these in token terms, so they are
    // estimates the user tunes (hence the gauge is always `inferred`). Read live from
    // the environment so an override applies without a rebuild (matches the Python
    // `os.environ.get` at call time, important for the env-override test).
    private static let defaultWindowCap = 200_000_000.0
    private static let defaultWeeklyCap = 800_000_000.0
    private static let windowDuration: TimeInterval = 5 * 60 * 60   // 5 hours
    private static let weeklyLookback: TimeInterval = 7 * 24 * 60 * 60  // 7 days

    private static func windowCap() -> Double { envCap("SICH_WINDOW_CAP_TOKENS", defaultWindowCap) }
    private static func weeklyCap() -> Double { envCap("SICH_WEEKLY_CAP_TOKENS", defaultWeeklyCap) }

    private static func envCap(_ key: String, _ fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[key], let value = Double(raw) else {
            return fallback
        }
        return value
    }

    /// The whole job: read the transcripts and assemble the four sources, mirroring
    /// `live.build_quota_response().sources`. Returns exactly four inputs, in this
    /// fixed order, NEVER netted against one another:
    ///   [0] anthropic/interactive       — estimated (inferred:true) from JSONL
    ///   [1] anthropic/agent_sdk_credit  — unknown (not locally observable)
    ///   [2] codex/codex                 — unknown
    ///   [3] gemini/gemini               — unknown
    ///
    /// `now` is injected (no inline system-clock read — testability) and truncated to
    /// whole seconds so the serialized `reset` stays second-resolution, matching the
    /// Python `build_quota_response`. `projectsDir` defaults to `~/.claude/projects`
    /// and is overridable for fixtures.
    public static func read(now: Date, projectsDir: URL = defaultProjectsDir) -> [QuotaSourceInput] {
        let truncatedNow = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.towardZero))
        let events = readUsageEvents(now: truncatedNow, projectsDir: projectsDir)
        return [interactiveSource(now: truncatedNow, events: events)] + nonLocalSources
    }

    /// Display-only split for the quota table: unlike the routing gauge above,
    /// this exposes the 5h and weekly constraints separately so the UI does not
    /// fake a second Claude column.
    public static func interactiveDisplaySources(
        now: Date, projectsDir: URL = defaultProjectsDir
    ) -> [QuotaSourceInput] {
        let truncatedNow = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.towardZero))
        let events = readUsageEvents(now: truncatedNow, projectsDir: projectsDir)
        let windowUsed = activeWindowUsage(events, now: truncatedNow)
        let weeklyUsed = events.reduce(0.0) { $0 + $1.amount }
        return [
            splitSource(pool: "interactive_5h",
                        remaining: fraction(windowCap() - windowUsed, cap: windowCap()),
                        reset: windowReset(events, now: truncatedNow),
                        refill: .rollingWindow,
                        inferred: true),
            splitSource(pool: "interactive_weekly",
                        remaining: fraction(weeklyCap() - weeklyUsed, cap: weeklyCap()),
                        reset: nil,
                        refill: .weekly,
                        inferred: true),
        ]
    }

    /// The three non-locally-observable pools, always `unknown` (never 0, never
    /// 100%). Constant — exposed so the live-endpoint path can prepend the real
    /// interactive reading without re-walking the JSONL just to rebuild these.
    public static let nonLocalSources: [QuotaSourceInput] = [
        unknownSource(provider: "anthropic", pool: "agent_sdk_credit"),
        unknownSource(provider: "codex", pool: "codex"),
        unknownSource(provider: "gemini", pool: "gemini"),
    ]

    /// `~/.claude/projects` — the default transcript root.
    public static var defaultProjectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // MARK: - Source assembly (port of live.live_sources)

    /// The interactive Anthropic pool, derived from window math (always `inferred`).
    /// An empty/absent transcript dir reads as fresh real-zero usage (full bar) —
    /// available + active — NOT `unknown` (the three non-local pools own that state).
    private static func interactiveSource(now: Date, events: [UsageEvent]) -> QuotaSourceInput {
        let weeklyUsed = events.reduce(0.0) { $0 + $1.amount }
        let result = interactiveRemaining(
            usage: events, now: now,
            windowCap: windowCap(), weeklyCap: weeklyCap(), weeklyUsed: weeklyUsed
        )
        return QuotaSourceInput(
            provider: "anthropic", pool: "interactive",
            reading: QuotaSourceReading(
                available: true,
                inferred: true,
                remainingFraction: result.remainingFraction,
                reset: result.reset,
                refillKind: .rollingWindow,
                state: result.remainingFraction <= 0.0 ? .exhausted : .active
            )
        )
    }

    /// A provider with no locally observable signal → `unknown` (never 0, never 100%).
    /// Mirrors `live.AbsentSource.read()` (`available:false, inferred:true`).
    private static func unknownSource(provider: String, pool: String) -> QuotaSourceInput {
        QuotaSourceInput(
            provider: provider, pool: pool,
            reading: QuotaSourceReading(available: false, inferred: true)
        )
    }

    private static func splitSource(
        pool: String, remaining: Double, reset: Date?, refill: QuotaRefillKind, inferred: Bool
    ) -> QuotaSourceInput {
        QuotaSourceInput(
            provider: "anthropic", pool: pool,
            reading: QuotaSourceReading(
                available: true,
                inferred: inferred,
                remainingFraction: remaining,
                reset: reset,
                refillKind: refill,
                state: remaining <= 0.0 ? .exhausted : .active
            )
        )
    }

    // MARK: - JSONL walk (port of jsonl_usage) — mtime-cached so an idle history is free

    /// All assistant-turn usage events within the 7d weekly lookback of `now`. Globs
    /// `**/*.jsonl` under `projectsDir`; an absent dir yields an empty list (real-zero,
    /// not unknown — see `interactiveSource`).
    ///
    /// A transcript unchanged since the last poll reuses its parsed events (keyed by
    /// mtime) instead of being re-decoded — so an idle `~/.claude/projects` costs a
    /// `stat()` per file, not a re-parse of 200MB+ of JSONL every tick (the fix for the
    /// constant-stutter bug: only the active session's growing file is re-read). The
    /// cache is rebuilt from the current file set each call, so vanished files drop out.
    /// ponytail: no old-file skip (mtime < since ⇒ no in-window event) — the cache
    /// already makes idle free, and it would wrongly exclude a fixture read at a fixed
    /// historical `now`; add it only if cold-start ever measures slow.
    public static func readUsageEvents(now: Date, projectsDir: URL = defaultProjectsDir) -> [UsageEvent] {
        let since = now.addingTimeInterval(-weeklyLookback)
        guard FileManager.default.fileExists(atPath: projectsDir.path) else { return [] }
        var next: [URL: CachedFile] = [:]
        let events = transcriptFiles(under: projectsDir).flatMap { url -> [UsageEvent] in
            guard let mtime = modificationDate(of: url) else {
                return eventsInFile(url, since: since)  // can't stat → always re-read, don't cache
            }
            let cached = incrementalRead(url, mtime: mtime, since: since)
            next[url] = cached
            return cached.events.filter { $0.at >= since }  // re-age on read (window slides forward)
        }
        fileCache = next
        return events
    }

    /// Unchanged file → cache hit. GROWN file (the active session's transcript,
    /// JSONL is append-only) → parse only the appended bytes from the cached offset
    /// and extend the cached events — the fix for re-decoding a multi-MB active
    /// transcript on every poll. Shrunk/rewritten file → full re-read.
    private static func incrementalRead(_ url: URL, mtime: Date, since: Date) -> CachedFile {
        let size = fileSize(of: url)
        if let cached = fileCache[url] {
            if cached.mtime == mtime, cached.parsedBytes == size { return cached }
            if size >= cached.parsedBytes {
                let (fresh, consumed) = eventsInFile(url, since: since, fromOffset: cached.parsedBytes)
                return CachedFile(mtime: mtime, parsedBytes: cached.parsedBytes + consumed,
                                  events: cached.events + fresh)
            }
        }
        let (events, consumed) = eventsInFile(url, since: since, fromOffset: 0)
        return CachedFile(mtime: mtime, parsedBytes: consumed, events: events)
    }

    private static func fileSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// A transcript's in-window events plus how far into the file they were parsed —
    /// a matching (mtime, parsedBytes) next poll means unchanged; a grown file is
    /// parsed only from `parsedBytes` on.
    private struct CachedFile { let mtime: Date; let parsedBytes: Int64; let events: [UsageEvent] }

    // ponytail: nonisolated(unsafe) — the poller's in-flight guard serializes reads, so
    // the single live reader owns this; tests key by unique per-case temp dirs.
    nonisolated(unsafe) private static var fileCache: [URL: CachedFile] = [:]

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Every `*.jsonl` under `projectsDir`, recursively. Skips unreadable subtrees.
    private static func transcriptFiles(under projectsDir: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    /// Parse one transcript, keeping only usage events at/after `since`. A malformed
    /// line is skipped (matches the Python `_events_in_file` try/except); an unreadable
    /// file yields no events — neither drops the rest. No whole-file drop on a bad line.
    static func eventsInFile(_ url: URL, since: Date) -> [UsageEvent] {
        eventsInFile(url, since: since, fromOffset: 0).events
    }

    /// Parse from a byte offset (0 = whole file), returning the events plus how many
    /// bytes were CONSUMED — only up to the last complete newline, so a partially
    /// written trailing line is left for the next poll instead of being skipped past.
    static func eventsInFile(
        _ url: URL, since: Date, fromOffset offset: Int64
    ) -> (events: [UsageEvent], consumed: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], 0) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return ([], 0) }
        // Consume only through the final newline; a torn trailing line stays unparsed.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        let complete = data[data.startIndex...lastNewline]
        guard let text = String(data: complete, encoding: .utf8) else {
            return ([], Int64(complete.count))   // undecodable chunk: skip it, keep moving
        }
        return (parseLines(text, since: since), Int64(complete.count))
    }

    private static func parseLines(_ text: String, since: Date) -> [UsageEvent] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            // `.literal` skips the Unicode-canonical/grapheme path of a plain `.contains`
            // (which profiled as the hot frame) — a byte-ish match is all a JSON key needs.
            guard line.range(of: "\"usage\"", options: .literal) != nil else { return nil }
            guard let event = parseUsageEvent(String(line)), event.at >= since else { return nil }
            return event
        }
    }

    /// Project one JSONL record (one line) to a `UsageEvent`, or `nil` to skip it:
    /// not an `assistant` turn, no `message.usage`, no/invalid `timestamp`, or
    /// un-parseable JSON. The `at` is truncated to whole seconds.
    static func parseUsageEvent(_ line: String) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "assistant",
              let message = record["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = record["timestamp"] as? String,
              let at = parseTimestamp(stamp)
        else { return nil }
        return UsageEvent(at: truncateToSecond(at), amount: usageTotal(usage))
    }

    /// Sum every token class on one assistant turn (the activity proxy) — mirrors the
    /// Python `_usage_total` (missing keys default to 0).
    private static func usageTotal(_ usage: [String: Any]) -> Double {
        func count(_ key: String) -> Double { (usage[key] as? NSNumber)?.doubleValue ?? 0 }
        return count("input_tokens") + count("output_tokens")
            + count("cache_creation_input_tokens") + count("cache_read_input_tokens")
    }

    /// Parse an ISO-8601 timestamp (with or without fractional seconds, `Z` or offset).
    /// Fractional first: Claude stamps carry milliseconds, so it's the common hit.
    private static func parseTimestamp(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }

    // Cached formatters — building an `ISO8601DateFormatter` opens a fresh ICU
    // formatter (`udat_open`), and doing that per-event across the whole transcript
    // history every poll pegged a CPU core (constant UI stutter). Configured once,
    // then only `date(from:)` is called — thread-safe for the detached reader.
    // ponytail: nonisolated(unsafe) — configured once, then only `date(from:)` is
    // called (thread-safe); the poller's in-flight guard also serializes readers.
    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func truncateToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.towardZero))
    }
}

// MARK: - Pure window/weekly math (port of window_math.interactive_remaining)

extension QuotaUsageReader {
    /// Output of `interactiveRemaining` — the remaining fraction (the tighter of the
    /// window/weekly constraints) and the binding reset.
    struct WindowResult: Equatable {
        let remainingFraction: Double
        let reset: Date
    }

    /// Remaining interactive capacity, bound by whichever cap is tighter — the Swift
    /// mirror of `window_math.interactive_remaining` (no `weekly_reset` is supplied
    /// here, exactly as `live.live_sources` calls it, so the reset is the window
    /// reset). The window and weekly caps are independent constraints; effective
    /// remaining is the smaller of the two fractions.
    static func interactiveRemaining(
        usage: [UsageEvent], now: Date, windowCap: Double, weeklyCap: Double, weeklyUsed: Double
    ) -> WindowResult {
        let windowUsed = activeWindowUsage(usage, now: now)
        let windowFraction = fraction(windowCap - windowUsed, cap: windowCap)
        let weeklyFraction = fraction(weeklyCap - weeklyUsed, cap: weeklyCap)
        return WindowResult(
            remainingFraction: min(windowFraction, weeklyFraction),
            reset: windowReset(usage, now: now)  // no weekly_reset supplied → window reset binds
        )
    }

    /// Sum usage whose age is still inside the rolling window at `now` (strict `>`,
    /// matching the Python so an event ages out exactly at +5h).
    private static func activeWindowUsage(_ usage: [UsageEvent], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-windowDuration)
        return usage.filter { $0.at > cutoff }.reduce(0.0) { $0 + $1.amount }
    }

    /// When the window first frees capacity = oldest in-window event ages out. With no
    /// active usage the window is fresh, so it resets a full duration out.
    private static func windowReset(_ usage: [UsageEvent], now: Date) -> Date {
        let cutoff = now.addingTimeInterval(-windowDuration)
        let inWindow = usage.map(\.at).filter { $0 > cutoff }
        guard let oldest = inWindow.min() else { return now.addingTimeInterval(windowDuration) }
        return oldest.addingTimeInterval(windowDuration)
    }

    /// Clamp `remaining / cap` to `[0.0, 1.0]`.
    private static func fraction(_ remaining: Double, cap: Double) -> Double {
        max(0.0, min(1.0, remaining / cap))
    }
}
