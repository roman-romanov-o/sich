import Foundation

/// Normalizes one Claude-Code-hook-shaped JSON line into a typed `SignalEvent` —
/// the native port of the (now-retired) Python detector's `hook_receiver`.
///
/// The `_HOOK_KIND` map is ported VERBATIM (US-003 AC2). A `PreToolUse` Bash call
/// running a known test runner is promoted to `testRunStart`. A hook with no
/// timestamp is stamped with its *arrival* time so staleness measures silence from
/// arrival, not epoch-min (the Python `IngestService` rule). A non-JSON line yields
/// `nil` (skipped, not fatal — US-003 edge 4).
///
/// Watcher discipline: this is a pure parse over already-received bytes. It spawns
/// nothing, opens no socket, and never replies.
public enum HookNormalizer {

    /// Claude Code hook event name → normalized signal kind. Ported verbatim from
    /// `hook_receiver._HOOK_KIND`. `Notification` means "Claude needs you" (permission
    /// prompt or idle nudge), so it maps to `permissionRequest` and lights attention.
    static let hookKind: [String: SignalKind] = [
        "SessionStart": .sessionStart,
        "session_start": .sessionStart,
        "UserPromptSubmit": .userInput,
        "user_prompt_submit": .userInput,
        "PreToolUse": .toolUse,
        "pre_tool_use": .toolUse,
        "PostToolUse": .toolUse,
        "post_tool_use": .toolUse,
        "PostToolUseFailure": .errorExit,
        "PermissionRequest": .permissionRequest,
        "permission_request": .permissionRequest,
        "Notification": .permissionRequest,
        "notification": .permissionRequest,
        "PermissionDenied": .errorExit,
        "PreCompact": .compaction,
        "pre_compact": .compaction,
        "SubagentStart": .subagentStart,
        "subagent_start": .subagentStart,
        "SubagentStop": .subagentStop,
        "subagent_stop": .subagentStop,
        "Stop": .stop,
        "stop": .stop,
        "StopFailure": .errorExit,
        "SessionEnd": .sessionEnd,
        "session_end": .sessionEnd,
    ]

    /// Substrings in a Bash command that mean "this tool call is a test run".
    /// Ported verbatim from `hook_receiver._TEST_RUNNERS`.
    static let testRunners: [String] = [
        "pytest", "jest", "vitest", "cargo test", "go test", "npm test",
    ]

    /// Map one hook line to a `SignalEvent`. `arrival` is injected (no inline clock
    /// read) so a missing timestamp stamps deterministically in tests. Returns `nil`
    /// when the line is not a JSON object.
    // periphery:ignore - test-only entry (scan runs with exclude_tests)
    public static func normalize(_ line: Data, arrival: Date) -> SignalEvent? {
        guard let payload = jsonObject(from: line) else { return nil }
        return normalize(payload: payload, arrival: arrival)
    }

    /// Payload-based entry for callers that already parsed the line (the event-file
    /// drain classifies every line from ONE `JSONSerialization` pass).
    public static func normalize(payload: [String: Any], arrival: Date) -> SignalEvent {
        SignalEvent(
            kind: resolveKind(payload),
            source: .hook,
            agent: resolveAgent(payload),
            sessionID: payload["session_id"] as? String ?? "",
            timestamp: SignalTimestamp.parse(payload["timestamp"], arrival: arrival),
            cwd: payload["cwd"] as? String,
            cardID: payload["sich_card_id"] as? String,
            // Present only on a relayed line: the channel stamped it at ingestion
            // (US-003 AC-2) and it is what keeps two machines apart (US-004 AC-3).
            host: payload[RemoteEventLine.hostKey] as? String
        )
    }

    // MARK: - Internals (mirror the Python helper functions one-for-one)

    private static func jsonObject(from line: Data) -> [String: Any]? {
        let object = try? JSONSerialization.jsonObject(with: line)
        return object as? [String: Any]
    }

    /// Map a hook event name to a kind, promoting test-running tool calls
    /// (port of `_resolve_kind`).
    private static func resolveKind(_ payload: [String: Any]) -> SignalKind {
        let name = payload["hook_event_name"] as? String ?? ""
        if name == "PreToolUse" && isTestCommand(payload) {
            return .testRunStart
        }
        return hookKind[name] ?? .unknown
    }

    private static func resolveAgent(_ payload: [String: Any]) -> CardAgent {
        let raw = payload["sich_agent"] as? String
            ?? payload["_sich_agent"] as? String
            ?? payload["_source"] as? String
            ?? payload["source"] as? String
        return raw.flatMap(CardAgent.init(rawValue:)) ?? .claude
    }

    /// True when a `PreToolUse` Bash command invokes a known test runner
    /// (port of `_is_test_command`).
    private static func isTestCommand(_ payload: [String: Any]) -> Bool {
        guard payload["tool_name"] as? String == "Bash" else { return false }
        let command = (payload["tool_input"] as? [String: Any])?["command"] as? String ?? ""
        return testRunners.contains { command.contains($0) }
    }
}
