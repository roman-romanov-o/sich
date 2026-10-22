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
        // Cursor's hook vocabulary (camelCase, `~/.cursor/hooks.json`). `stop` is the
        // agent-loop end (= Claude's Stop), `sessionEnd` the conversation close.
        "sessionStart": .sessionStart,
        "beforeSubmitPrompt": .userInput,
        "preToolUse": .toolUse,
        "postToolUse": .toolUse,
        "postToolUseFailure": .errorExit,
        "preCompact": .compaction,
        "subagentStart": .subagentStart,
        "subagentStop": .subagentStop,
        "sessionEnd": .sessionEnd,
        // Antigravity (`~/.gemini/config/hooks.json`) has five events and NO name
        // field on its payload — the installed command names the event and the
        // hook script stamps it in. Model-invocation edges are "working" too.
        "PreInvocation": .toolUse,
        "PostInvocation": .toolUse,
    ]

    /// Hook event names that precede a tool call — the point where a test runner is
    /// recognised (Claude/Codex `PreToolUse`, Cursor `preToolUse`).
    static let preToolUseNames: Set<String> = ["PreToolUse", "preToolUse"]

    /// Tool names whose `tool_input.command` is a shell line (Claude/Codex `Bash`,
    /// Cursor `Shell`).
    static let shellToolNames: Set<String> = ["Bash", "Shell"]

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
            // Cursor keys the conversation as `conversation_id`; the field means the
            // same thing (the resumable chat) so it folds into `sessionID`.
            sessionID: payload["session_id"] as? String
                ?? payload["conversation_id"] as? String
                ?? payload["conversationId"] as? String ?? "",
            timestamp: SignalTimestamp.parse(payload["timestamp"], arrival: arrival),
            cwd: payload["cwd"] as? String ?? firstWorkspaceRoot(payload),
            cardID: payload["sich_card_id"] as? String,
            // Present only on a relayed line: the channel stamped it at ingestion
            // (US-003 AC-2) and it is what keeps two machines apart (US-004 AC-3).
            host: payload[RemoteEventLine.hostKey] as? String,
            backgroundBusy: resolveBackgroundBusy(payload)
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
        if preToolUseNames.contains(name) && isTestCommand(payload) {
            return .testRunStart
        }
        // The idle nudge ("Claude is waiting for your input") is the turn boundary
        // restated, not a permission ask — route it through `stop` so it shares the
        // background-subagent masking (a nudge fired while a backgrounded child is
        // still working must not light NEEDS YOU). Permission notifications keep the
        // verbatim `permissionRequest` mapping.
        if name == "Notification" && payload["notification_type"] as? String == "idle_prompt" {
            return .stop
        }
        return hookKind[name] ?? .unknown
    }

    /// Fold the payload's `background_tasks` array into one flag: is a background
    /// subagent still running? A `SubagentStop` lists the stopping agent ITSELF as
    /// `running`, so the event's own `agent_id` is excluded. `nil` when the payload
    /// carries no array — the store then falls back to its last-known flag.
    private static func resolveBackgroundBusy(_ payload: [String: Any]) -> Bool? {
        guard let tasks = payload["background_tasks"] as? [[String: Any]] else { return nil }
        let selfID = payload["agent_id"] as? String
        return tasks.contains { task in
            task["status"] as? String == "running" && task["id"] as? String != selfID
        }
    }

    /// Cursor carries no `cwd` on most events, only `workspace_roots` (Antigravity:
    /// `workspacePaths`); the first root is the directory the agent was launched in.
    private static func firstWorkspaceRoot(_ payload: [String: Any]) -> String? {
        (payload["workspace_roots"] as? [String])?.first
            ?? (payload["workspacePaths"] as? [String])?.first
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
        guard let tool = payload["tool_name"] as? String, shellToolNames.contains(tool)
        else { return false }
        let command = (payload["tool_input"] as? [String: Any])?["command"] as? String ?? ""
        return testRunners.contains { command.contains($0) }
    }
}
