import Foundation

/// Normalizes one Claude Code JSONL transcript record into a `SignalEvent` — the
/// native port of the (now-retired) Python detector's `jsonl_tail`.
///
/// JSONL is the reconciliation FALLBACK (lower precedence than hooks): a dropped
/// `Stop` hook is recovered by a `turn_completed` transcript record, so a session
/// still converges to `done` instead of locking in `running` (US-003 AC1 — raced/
/// dropped hooks reconcile). The transport (`tail -f` / FSEvents) is out of scope;
/// this is a pure parse over an already-read record.
public enum JSONLNormalizer {

    /// JSONL transcript record `type` → normalized signal kind (port of `_JSONL_KIND`).
    static let jsonlKind: [String: SignalKind] = [
        "turn_completed": .stop,
        "turn_started": .sessionStart,
        "tool_use": .toolUse,
        "tool_result": .toolUse,
        "error": .errorExit,
    ]

    /// Map one transcript line to a `SignalEvent`; `nil` on non-JSON. `arrival`
    /// stamps a timestamp-less record (same rule as the hook normalizer).
    public static func normalize(_ line: Data, arrival: Date) -> SignalEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let record = object as? [String: Any] else { return nil }
        return normalize(payload: record, arrival: arrival)
    }

    /// Payload-based entry for callers that already parsed the line (the event-file
    /// drain classifies every line from ONE `JSONSerialization` pass).
    public static func normalize(payload record: [String: Any], arrival: Date) -> SignalEvent {
        SignalEvent(
            kind: jsonlKind[record["type"] as? String ?? ""] ?? .unknown,
            source: .jsonl,
            sessionID: record["session_id"] as? String ?? "",
            timestamp: SignalTimestamp.parse(record["timestamp"], arrival: arrival),
            cwd: record["cwd"] as? String
        )
    }
}
