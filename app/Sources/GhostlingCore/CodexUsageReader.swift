import Foundation

/// Measured Codex quota from the CLI's OWN persisted telemetry — the on-disk
/// sibling of the Claude `/usage` scrape. Codex writes a `rate_limits` snapshot
/// into every session rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`,
/// inside `payload.rate_limits` of the `token_count` event) on every API call.
/// Each constraint carries `used_percent`, `window_minutes`, and an epoch-seconds
/// `resets_at`; do not infer the window from the `primary`/`secondary` key because
/// some plans currently persist a weekly-only `primary` with `secondary: null`.
/// Reading the newest snapshot
/// is a pure file read — no credentials, no prompt, no spawn (watcher-pure) —
/// and yields a real `measured` gauge for the codex pool.
///
/// Honest degradation: no rollouts / no snapshot → `nil`, and the caller keeps
/// the `unknown` codex source (never 0, never 100%). A constraint whose
/// `resets_at` is already past reads as 0% used: the window rolled over, and
/// since Codex writes a rollout line on every call, no newer line means no
/// usage in the fresh window.
public enum CodexUsageReader {

    /// `~/.codex/sessions` — where the Codex CLI persists its rollouts.
    public static var defaultSessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// One rate-limit constraint as Codex persists it.
    public struct Constraint: Sendable, Equatable {
        public let usedPercent: Double
        public let windowMinutes: Double
        public let resetsAt: Date

        public init(usedPercent: Double, windowMinutes: Double, resetsAt: Date) {
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }
    }

    /// The last persisted `rate_limits` snapshot. Either constraint may be absent
    /// in a partial write; `window_minutes`, not the key name, identifies 5h vs weekly.
    public struct Snapshot: Sendable, Equatable {
        public let primary: Constraint?
        public let secondary: Constraint?

        public init(primary: Constraint?, secondary: Constraint?) {
            self.primary = primary
            self.secondary = secondary
        }
    }

    // MARK: - Public entry

    /// The measured codex source, or `nil` when no telemetry exists (caller keeps
    /// the unknown source). `now`/`sessionsDir` injected for fixture tests.
    public static func source(
        now: Date = Date(), sessionsDir: URL = defaultSessionsDir
    ) -> QuotaSourceInput? {
        // ponytail: scan the newest rollouts — the current session's file
        // virtually always carries the snapshot; widen if a snapshot-less
        // rollout backlog ever shows up in practice.
        return mergedSnapshot(in: rolloutFiles(in: sessionsDir).prefix(10)).flatMap {
            source(from: $0, now: now)
        }
    }

    // MARK: - Mapping (mirrors ClaudeUsagePanel.interactiveSource binding logic)

    /// Map a snapshot onto the codex gauge: the BINDING constraint (higher
    /// effective used%) decides remaining, reset and refill kind — same rule as
    /// the Claude session-vs-week mapping. `inferred:false`: this is the CLI's
    /// own measurement, not our estimate.
    public static func source(from snapshot: Snapshot, now: Date) -> QuotaSourceInput? {
        let views = [snapshot.primary, snapshot.secondary]
            .compactMap { $0.map { effective($0, now: now) } }
        // max(by:) keeps the FIRST of equals → primary wins ties, matching the
        // `session >= week` binding in the Claude mapping.
        guard let binding = views.max(by: { $0.used < $1.used }) else { return nil }
        let remaining = max(0.0, min(1.0, 1.0 - binding.used / 100.0))
        return QuotaSourceInput(
            provider: "codex", pool: "codex",
            reading: QuotaSourceReading(
                available: true,
                inferred: false,
                remainingFraction: remaining,
                reset: binding.reset,
                refillKind: binding.refill,
                state: remaining <= 0.0 ? .exhausted : .active
            )
        )
    }

    public static func displaySources(
        now: Date = Date(), sessionsDir: URL = defaultSessionsDir
    ) -> [QuotaSourceInput]? {
        mergedSnapshot(in: rolloutFiles(in: sessionsDir).prefix(10)).flatMap {
            displaySources(from: $0, now: now)
        }
    }

    public static func displaySources(from snapshot: Snapshot, now: Date) -> [QuotaSourceInput]? {
        var sources: [QuotaSourceInput] = []
        if let primary = snapshot.primary {
            sources.append(splitSource(primary, now: now))
        }
        if let secondary = snapshot.secondary {
            let source = splitSource(secondary, now: now)
            if !sources.contains(where: { $0.pool == source.pool }) {
                sources.append(source)
            }
        }
        return sources.isEmpty ? nil : sources
    }

    private static func splitSource(_ constraint: Constraint, now: Date) -> QuotaSourceInput {
        let view = effective(constraint, now: now)
        let pool = view.refill == .rollingWindow ? "codex_5h" : "codex_weekly"
        let remaining = max(0.0, min(1.0, 1.0 - view.used / 100.0))
        return QuotaSourceInput(
            provider: "codex", pool: pool,
            reading: QuotaSourceReading(
                available: true,
                inferred: false,
                remainingFraction: remaining,
                reset: view.reset,
                refillKind: view.refill,
                state: remaining <= 0.0 ? .exhausted : .active
            )
        )
    }

    /// A constraint's current view: past `resets_at` means the window already
    /// rolled over → 0% used (no newer rollout line = no usage since), and the
    /// next reset instant is unknown → nil.
    private static func effective(
        _ c: Constraint, now: Date
    ) -> (used: Double, reset: Date?, refill: QuotaRefillKind) {
        let refill: QuotaRefillKind = c.windowMinutes < 1440 ? .rollingWindow : .weekly
        guard c.resetsAt > now else { return (0.0, nil, refill) }
        return (c.usedPercent, c.resetsAt, refill)
    }

    // MARK: - Rollout discovery + tail parse

    /// All `rollout-*.jsonl` under the sessions tree, newest mtime first.
    static func rolloutFiles(in dir: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            files.append((url, mtime))
        }
        return files.sorted { $0.mtime > $1.mtime }.map(\.url)
    }

    /// The newest `rate_limits` snapshot in a rollout: read the tail chunk and
    /// scan lines backwards. A line truncated by the chunk boundary just fails
    /// the JSON parse and is skipped.
    static func lastSnapshot(in file: URL, tailBytes: UInt64 = 262_144) -> Snapshot? {
        snapshots(in: file, tailBytes: tailBytes).first
    }

    static func snapshots(in file: URL, tailBytes: UInt64 = 262_144) -> [Snapshot] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        let marker = Data("\"rate_limits\"".utf8)
        var snapshots: [Snapshot] = []
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.firstRange(of: marker) != nil,
                  let snapshot = parseLine(Data(line))
            else { continue }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    /// Newer Codex builds may emit only the changed quota window in a given
    /// `rate_limits` event (for example weekly-only `primary` with `secondary:
    /// null`). Merge recent tail snapshots by window so a weekly-only event does
    /// not erase the newest 5h reading from a neighbouring line/session.
    static func mergedSnapshot<S: Sequence>(in files: S) -> Snapshot? where S.Element == URL {
        var rolling: Constraint?
        var weekly: Constraint?
        for file in files {
            for snapshot in snapshots(in: file) {
                for constraint in [snapshot.primary, snapshot.secondary].compactMap({ $0 }) {
                    if constraint.windowMinutes < 1440 {
                        rolling = rolling ?? constraint
                    } else {
                        weekly = weekly ?? constraint
                    }
                }
                if rolling != nil, weekly != nil {
                    return Snapshot(primary: rolling, secondary: weekly)
                }
            }
        }
        guard rolling != nil || weekly != nil else { return nil }
        return Snapshot(primary: rolling, secondary: weekly)
    }

    /// One rollout line → snapshot. The event shape is
    /// `{"payload":{"rate_limits":{"primary":{...},"secondary":{...}}}}`; the
    /// top-level fallback tolerates a future un-nesting.
    static func parseLine(_ data: Data) -> Snapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? obj
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let primary = constraint(limits["primary"])
        let secondary = constraint(limits["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return Snapshot(primary: primary, secondary: secondary)
    }

    private static func constraint(_ raw: Any?) -> Constraint? {
        guard let dict = raw as? [String: Any],
              let used = dict["used_percent"] as? Double,
              let window = dict["window_minutes"] as? Double,
              let resets = dict["resets_at"] as? Double
        else { return nil }
        return Constraint(
            usedPercent: used, windowMinutes: window,
            resetsAt: Date(timeIntervalSince1970: resets)
        )
    }
}
