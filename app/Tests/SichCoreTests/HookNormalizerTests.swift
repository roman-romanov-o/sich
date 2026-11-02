import Foundation
import SichCore
import Testing

/// The hook normalizer's classification of the "Claude needs you" signals (US-002
/// AC#3 / TC-UNIT-013). A real Claude Code `Notification` hook (a permission prompt or
/// idle nudge) is a POSITIVE attention signal — it must normalize to
/// `permissionRequest` and reconcile to a `waitingForInput` state that routes the
/// operator's attention, never fall through to `unknown` (which would silently drop the
/// "needs you" badge).
///
/// Pure parse over already-received bytes: spawns nothing, opens no socket, injects the
/// clock (`arrival`) so a timestamp-less payload is deterministic.
struct HookNormalizerTests {
    private let arrival = Date(timeIntervalSince1970: 1_750_000_000)

    private func normalize(_ json: String) -> SignalEvent? {
        HookNormalizer.normalize(Data(json.utf8), arrival: arrival)
    }

    // MARK: - TC-UNIT-013: permission hook → needs-attention

    @Test func permissionHook_setsAttention() throws {
        // The real Claude Code permission-prompt hook name is `Notification`.
        let event = try #require(
            normalize(#"{"hook_event_name":"Notification","session_id":"S","cwd":"/repo"}"#))
        #expect(event.kind == .permissionRequest,
                "a permission/notification hook must classify positively, not as unknown")

        // …and it reconciles to a waiting state that routes attention (the "needs you"
        // signal the header counts).
        let store = HookSessionStore()
        store.ingest([event])
        let entry = try #require(store.entry(for: "S"))
        #expect(entry.state == .waitingForInput)
        #expect(entry.state.needsAttention)
    }

    @Test func codexSessionStartIsIdleUntilPromptSubmit() throws {
        let start = try #require(
            normalize(#"{"hook_event_name":"SessionStart","sich_agent":"codex","session_id":"C","cwd":"/repo"}"#))
        #expect(start.agent == .codex)
        #expect(start.kind == .sessionStart)

        let store = HookSessionStore()
        store.ingest([start])
        #expect(store.entry(for: "C")?.state == .idle)

        let prompt = try #require(
            normalize(#"{"hook_event_name":"UserPromptSubmit","sich_agent":"codex","session_id":"C","cwd":"/repo"}"#))
        store.ingest([prompt])
        #expect(store.entry(for: "C")?.state == .running)
    }

    @Test func cursorCamelCaseVocabularyDrivesTheSameLifecycle() throws {
        func cursor(_ name: String, extra: String = "") throws -> SignalEvent {
            try #require(normalize(
                #"{"hook_event_name":"\#(name)","sich_agent":"cursor","conversation_id":"conv-1","sich_pid":"98009","workspace_roots":["/repo"]\#(extra)}"#))
        }
        let start = try cursor("sessionStart")
        #expect(start.agent == .cursor)
        #expect(start.kind == .sessionStart)
        #expect(start.sessionID == "cursor:98009",
                "a Cursor session is the launched `agent` process, not its conversation_id")
        #expect(start.cwd == "/repo", "no cwd on the payload → first workspace root")

        let store = HookSessionStore()
        store.ingest([start])
        #expect(store.entry(for: "cursor:98009")?.state == .idle)
        store.ingest([try cursor("beforeSubmitPrompt")])
        #expect(store.entry(for: "cursor:98009")?.state == .running)
        #expect(try cursor("preToolUse", extra: #","tool_name":"Read""#).kind == .toolUse)
        #expect(try cursor("postToolUseFailure").kind == .toolUse,
                "a failed tool call is the agent at work, not an external block")
        #expect(try cursor("preCompact").kind == .compaction)
        #expect(try cursor("subagentStart").kind == .subagentStart)
        #expect(try cursor("subagentStop").kind == .subagentStop)
        store.ingest([try cursor("stop")])
        #expect(store.entry(for: "cursor:98009")?.state == .waitingForInput)
        store.ingest([try cursor("sessionEnd")])
        #expect(store.entry(for: "cursor:98009")?.state == .idle)
    }

    /// The operator report (2026-10-28, the "#53" Cursor card): one review turn
    /// flapped WORKING → NEEDS YOU → BLOCKED → … while its commands ran. The
    /// recorded events.jsonl explains it: the turn fanned out to two subagents that
    /// fired hooks under their OWN `conversation_id`s, some tool events of the turn
    /// carried the id of the card's EARLIER chat (already Stop-latched), and three
    /// ordinary tool failures (file not found, `tsc` missing, a red vitest) each
    /// classified as `blocked`. The board picked the freshest of four entries every
    /// poll. All of it is ONE `agent` process: it must be one session whose only
    /// transitions are the prompt and the turn end.
    @Test func cursorSubagentsAndStaleChatIDsFoldIntoTheLaunchedProcess() throws {
        func event(_ name: String, conv: String, at offset: TimeInterval, extra: String = "") throws -> SignalEvent {
            try #require(normalize(
                #"{"hook_event_name":"\#(name)","sich_agent":"cursor","sich_pid":"98009","sich_card_id":"CARD","conversation_id":"\#(conv)","workspace_roots":["/repo"],"timestamp":\#(arrival.timeIntervalSince1970 + offset)\#(extra)}"#))
        }
        let store = HookSessionStore(stallThreshold: 600)
        // The card's first chat: checkout the PR, two `gh` failures, turn end.
        store.ingest([try event("beforeSubmitPrompt", conv: "old-chat", at: 0)])
        store.ingest([try event("postToolUseFailure", conv: "old-chat", at: 5, extra: #","tool_name":"Shell","error_message":"Repository not found""#)])
        store.ingest([try event("stop", conv: "old-chat", at: 10)])
        #expect(store.entry(for: "cursor:98009")?.state == .waitingForInput)

        // The review turn in a NEW chat of the same process.
        store.ingest([try event("beforeSubmitPrompt", conv: "root", at: 100)])
        store.ingest([try event("preToolUse", conv: "sub-a", at: 105, extra: #","tool_name":"Read""#)])
        store.ingest([try event("postToolUse", conv: "old-chat", at: 110, extra: #","tool_name":"Grep""#)])
        store.ingest([try event("postToolUseFailure", conv: "sub-b", at: 115, extra: #","tool_name":"Read","error_message":"File not found""#)])
        store.ingest([try event("postToolUse", conv: "sub-a", at: 120, extra: #","tool_name":"Shell""#)])
        store.ingest([try event("postToolUseFailure", conv: "sub-b", at: 125, extra: #","tool_name":"Shell","error_message":"sh: tsc: command not found""#)])
        #expect(store.entry(for: "cursor:98009")?.state == .running)
        #expect(store.entry(for: "sub-a") == nil, "a subagent is not a session of its own")
        #expect(store.entry(for: "old-chat") == nil)

        // Mid-turn silence of the root (it is waiting on the subagents) is covered
        // by the subagents' own hooks — no stall-guard NEEDS YOU.
        store.sweepStale(now: arrival.addingTimeInterval(700))
        #expect(store.entry(for: "cursor:98009")?.state == .running)

        store.ingest([try event("stop", conv: "root", at: 710, extra: #","status":"completed""#)])
        #expect(store.entry(for: "cursor:98009")?.state == .waitingForInput)
        #expect(store.transitions(for: "cursor:98009")
                == [.running, .waitingForInput, .running, .waitingForInput],
                "two prompts, two turn ends — nothing in between moved the card")
    }

    @Test func antigravityEventsStampedByTheScriptDriveTheLifecycle() throws {
        func agy(_ name: String) throws -> SignalEvent {
            try #require(normalize(
                #"{"hook_event_name":"\#(name)","sich_agent":"antigravity","conversationId":"agy-1","workspacePaths":["/repo"],"modelName":"gemini-3-pro"}"#))
        }
        let pre = try agy("PreInvocation")
        #expect(pre.agent == .antigravity)
        #expect(pre.kind == .toolUse)
        #expect(pre.sessionID == "agy-1", "Antigravity names the session conversationId")
        #expect(pre.cwd == "/repo", "no cwd on the payload → first workspacePaths entry")

        let store = HookSessionStore()
        store.ingest([pre])
        #expect(store.entry(for: "agy-1")?.state == .running)
        #expect(try agy("PostToolUse").kind == .toolUse)
        #expect(try agy("PostInvocation").kind == .toolUse)
        store.ingest([try agy("Stop")])
        #expect(store.entry(for: "agy-1")?.state == .waitingForInput)
    }

    @Test func cursorShellToolRunningTestsIsATestRun() throws {
        let event = try #require(normalize(
            #"{"hook_event_name":"preToolUse","sich_agent":"cursor","conversation_id":"c","cwd":"/repo","tool_name":"Shell","tool_input":{"command":"pytest -q"}}"#))
        #expect(event.kind == .testRunStart)
    }

    @Test func codexSnakeCasePermissionRequestSetsAttention() throws {
        let event = try #require(
            normalize(#"{"hook_event_name":"permission_request","sich_agent":"codex","session_id":"C"}"#))
        #expect(event.kind == .permissionRequest)
        #expect(event.agent == .codex)

        let store = HookSessionStore()
        store.ingest([event])
        #expect(store.entry(for: "C")?.state == .waitingForInput)
    }

    @Test func codexSubagentLifecycleStaysWorkingUntilRootStop() throws {
        func codex(_ name: String, at offset: TimeInterval) throws -> SignalEvent {
            try #require(normalize(
                #"{"hook_event_name":"\#(name)","sich_agent":"codex","session_id":"C","timestamp":\#(arrival.timeIntervalSince1970 + offset)}"#
            ))
        }

        let store = HookSessionStore(stallThreshold: 600)
        store.ingest([try codex("UserPromptSubmit", at: 0)])
        store.ingest([try codex("SubagentStart", at: 2)])
        #expect(store.entry(for: "C")?.state == .running)

        // The main agent can be silent while it waits for the child, then while it
        // collects that result. Within the stall budget neither interval is a
        // user-facing wait (CARD-STATUS.md rule 2: waiting-for-subagent is WORKING).
        store.sweepStale(now: arrival.addingTimeInterval(120))
        #expect(store.entry(for: "C")?.state == .running)
        store.ingest([try codex("SubagentStop", at: 121)])
        store.sweepStale(now: arrival.addingTimeInterval(240))
        #expect(store.entry(for: "C")?.state == .running)

        store.ingest([try codex("Stop", at: 241)])
        #expect(store.entry(for: "C")?.state == .waitingForInput)
        #expect(store.entry(for: "C")?.state.needsAttention == true)

        store.ingest([try codex("UserPromptSubmit", at: 242)])
        #expect(store.entry(for: "C")?.state == .running)
    }

    /// The subagent-turn quiet budget is BOUNDED by the stall guard: if the root
    /// Stop is lost (crash / dropped hook / truly hung child), the card cannot stay
    /// pinned to WORKING forever — past the stall threshold it routes to NEEDS YOU
    /// (CARD-STATUS.md rule 2.1: a genuinely progressing child fires its own tool
    /// hooks, which reset the timer).
    @Test func subagentTurnStillRecoversWhenRootStopIsLost() throws {
        func codex(_ name: String, at offset: TimeInterval) throws -> SignalEvent {
            try #require(normalize(
                #"{"hook_event_name":"\#(name)","sich_agent":"codex","session_id":"C","timestamp":\#(arrival.timeIntervalSince1970 + offset)}"#
            ))
        }

        // Fast, deterministic clock: a 10s stall budget instead of the default 10 min.
        let store = HookSessionStore(stallThreshold: 10)
        store.ingest([try codex("UserPromptSubmit", at: 0)])
        store.ingest([try codex("SubagentStart", at: 1)])
        #expect(store.entry(for: "C")?.state == .running)

        // Within the stall budget: still WORKING.
        store.sweepStale(now: arrival.addingTimeInterval(6))
        #expect(store.entry(for: "C")?.state == .running)

        // Root Stop never arrives. Past the budget the stall guard routes attention.
        store.sweepStale(now: arrival.addingTimeInterval(20))
        #expect(store.entry(for: "C")?.state == .waitingForInput)
    }

    // MARK: - background_tasks parsing (CARD-STATUS.md rule 2.3)

    @Test func backgroundTasksFoldToOneFlag() throws {
        // Running child → busy; the payload is the live-capture Stop shape.
        let busy = try #require(normalize(
            #"{"hook_event_name":"Stop","session_id":"S","background_tasks":[{"id":"a1","type":"subagent","status":"running"}]}"#))
        #expect(busy.backgroundBusy == true)

        // All children finished → not busy; absent array → nil (older Claude).
        let drained = try #require(normalize(
            #"{"hook_event_name":"Stop","session_id":"S","background_tasks":[{"id":"a1","status":"completed"}]}"#))
        #expect(drained.backgroundBusy == false)
        let absent = try #require(normalize(#"{"hook_event_name":"Stop","session_id":"S"}"#))
        #expect(absent.backgroundBusy == nil)

        // A SubagentStop lists the stopping agent ITSELF as still running — its own
        // id must not count as an open child.
        let selfListed = try #require(normalize(
            #"{"hook_event_name":"SubagentStop","session_id":"S","agent_id":"a1","background_tasks":[{"id":"a1","status":"running"}]}"#))
        #expect(selfListed.backgroundBusy == false,
                "the stopping agent's own entry is not a still-open background task")

        // A backgrounded SHELL (live capture: a Metro dev server left running by
        // `run_in_background`) is not a child the turn waits on — the Stop that
        // leaves it running is a real turn end.
        let shellOnly = try #require(normalize(
            #"{"hook_event_name":"Stop","session_id":"S","background_tasks":[{"id":"bpws0wrz7","type":"shell","status":"running","description":"Start Metro dev server"}]}"#))
        #expect(shellOnly.backgroundBusy == false,
                "a running background shell does not hold the background parenthesis open")
    }

    /// The idle nudge is the turn boundary restated — it must route through `stop`
    /// (sharing the background-parenthesis masking), while a permission Notification
    /// keeps the verbatim `permissionRequest` mapping.
    @Test func idleNudgeRoutesThroughStop() throws {
        let nudge = try #require(normalize(
            #"{"hook_event_name":"Notification","session_id":"S","notification_type":"idle_prompt"}"#))
        #expect(nudge.kind == .stop)
        let permission = try #require(normalize(
            #"{"hook_event_name":"Notification","session_id":"S","message":"Claude needs your permission to use Bash"}"#))
        #expect(permission.kind == .permissionRequest)
    }
}
