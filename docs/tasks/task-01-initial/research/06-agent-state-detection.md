# Research: Per-Session Agent State Detection (Claude Code, Codex CLI, Gemini CLI)

**Date:** 2026-04-27
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

State detection is **highly feasible for Claude Code** (rich hooks system with HTTP-target support, 28 lifecycle events including `Notification`, `Stop`, `PermissionRequest`, `PreToolUse`/`PostToolUse`, `TeammateIdle`), **highly feasible for Codex CLI** (JSON-RPC `app-server` exposes turn/thread lifecycle as a streaming notification feed, plus a maturing hooks system), and **medium-feasibility for Gemini CLI** (full hooks system with `SessionStart`/`SessionEnd`/`Notification`/agent lifecycle, but only stdin/stdout — no native HTTP, so it requires a wrapper). The dashboard can build a unified state model `{idle, running, awaiting-human, running-tests, blocked, done}` for all three with high confidence. The dominant risk is not "can we detect state" but "can we reliably *route* state events from N parallel sessions to one daemon" — solved easily by HTTP hooks (Claude Code natively, Codex/Gemini via a 10-line shell wrapper).

## State Model the Dashboard Needs

The dashboard's job is to classify each session into one of:

- **idle** — session exists but agent is not actively generating (between turns).
- **running** — agent is generating tokens or executing tools.
- **awaiting-human** — permission prompt, elicitation dialog, or "Stop hook fired and user hasn't typed yet" with no further activity.
- **running-tests** — tool call is a test runner / long bash; orthogonal to "running" and inferred from tool input.
- **blocked** — error state, rate-limit, auth failure, tool failure.
- **done** — agent finished a turn cleanly with no follow-up needed.

Below: feasibility per agent.

## Claude Code — Signal Quality: HIGH

### Available hook events (April 2026)

Source: [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks). 28 documented hook events. Most relevant for state detection:

| Hook event | When it fires | State implication | HTTP-capable |
|---|---|---|---|
| `SessionStart` | Session begins/resumes | session registered | Command/MCP only |
| `SessionEnd` | Session terminates | session removed | Yes |
| `UserPromptSubmit` | User submits a prompt | running (turn started) | Yes |
| `PreToolUse` | Before tool exec | running, with `tool_name` (Bash, Edit, etc.) | Yes |
| `PostToolUse` | Tool succeeds | still running, but tool done; can detect tests via `tool_input.command` | Yes |
| `PostToolUseFailure` | Tool fails | blocked / error counter++ | Yes |
| `Notification` (matcher: `permission_prompt`) | Permission dialog appears | awaiting-human | Yes |
| `Notification` (matcher: `idle_prompt`) | Claude is idle waiting for user | awaiting-human | Yes |
| `PermissionRequest` | Permission prompt opens | awaiting-human | Yes |
| `PermissionDenied` | Auto-denied | blocked | Yes |
| `Stop` | Claude finishes responding | done (or back to idle) | Yes |
| `StopFailure` | Turn ended due to API error | blocked | Yes |
| `TeammateIdle` | Agent teammate going idle | idle | Yes |
| `SubagentStart` / `SubagentStop` | Subagent lifecycle | nested running state | Yes |
| `PreCompact` / `PostCompact` | Context compaction | running (advisory) | Yes |
| `CwdChanged` | Working directory changed | dashboard re-correlates session to project | Yes |

### How to wire it up

- **HTTP hook native support** is the killer feature. The dashboard runs a local HTTP server on, e.g., `127.0.0.1:7891`, and a single user-level `~/.claude/settings.json` registers hooks like:
```json
{
  "hooks": {
    "Stop": [{"type": "http", "url": "http://127.0.0.1:7891/hooks/stop", "timeout": 2}],
    "Notification": [{"type": "http", "url": "http://127.0.0.1:7891/hooks/notification", "timeout": 2}],
    "PreToolUse": [{"type": "http", "url": "http://127.0.0.1:7891/hooks/pre-tool", "timeout": 2}],
    "PostToolUseFailure": [{"type": "http", "url": "http://127.0.0.1:7891/hooks/error", "timeout": 2}]
  }
}
```
- **Every event POSTs the full JSON payload** including `session_id`, `transcript_path`, `cwd`, `permission_mode`, and event-specific fields (`tool_name`, `tool_input`, `notification_type`, etc.).
- **Correlation key:** `cwd` (project) + `session_id` (specific session in that project).
- **Latency:** sub-second, push-based, no polling.

### Fallback: tail JSONL

`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` is updated in real time during a session. It contains the full transcript stream including assistant messages, tool calls, tool results. A `tail -f` on the file reveals identical state info to hooks but with more parsing work and weaker semantics for "permission prompt is open right now". **Use as backup, not primary.**

### What's hard / unreliable

- **"Idle waiting for user" vs. "still computing":** distinguishing "Stop fired but user might type any moment" from "agent finished and is genuinely idle" is timing-based. Easy heuristic: `Stop` -> set state to `awaiting-human` immediately; if `UserPromptSubmit` fires within N seconds, it was just a normal turn boundary.
- **"Running tests" classification:** require the dashboard to inspect `tool_input.command` for `PreToolUse` with `tool_name: Bash` and look for `pytest|jest|vitest|cargo test|go test|npm test`. Heuristic, not perfect, but workable.
- **Hook firing on slow HTTP endpoint can stall the agent.** Use small timeouts (1–2s) and respond with `200 OK` immediately — process the event async on the daemon side.

### Verdict: HIGH

The richness of Claude Code hooks is the single most important enabling fact for the entire mission-control idea. State detection is essentially a solved problem if you trust the documented hook surface.

## Codex CLI — Signal Quality: HIGH

### Two complementary signal sources

#### A. The `app-server` JSON-RPC stream (richer)

Source: [codex-rs/app-server/README.md](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md), [codex.danielvaughan.com cross-surface session sync post](https://codex.danielvaughan.com/2026/04/08/cross-surface-session-sync/).

Codex's CLI, Desktop, and VS Code clients all attach to one long-lived `app-server` process exposing JSON-RPC 2.0. Transports: **stdio (default), WebSocket, Unix socket** (the unix socket option matters: it means the dashboard daemon can attach as a peer client without spawning anything).

Notifications the server emits per running turn:

| Notification | State implication |
|---|---|
| `thread/started` | session registered |
| `thread/status/changed` (`idle`, `active`, `systemError`) | direct state transition |
| `thread/closed` | session removed |
| `turn/started` | running |
| `turn/completed` (status: completed/interrupted/failed) | done / blocked |
| `item/started` (with item type: `agentMessage`, `commandExecution`, `fileChange`, `mcpToolCall`, `reasoning`, `plan`) | sub-state ("currently editing files") |
| `item/agentMessage/delta` | streaming tokens |
| `item/completed` | item done |
| `item/commandExecution/requestApproval` | awaiting-human |
| `item/fileChange/requestApproval` | awaiting-human |
| `thread/tokenUsage/updated` | token-burn signal for quota layer |

The `thread/status/changed` notification with explicit `idle`/`active`/`systemError` states maps almost 1:1 onto the dashboard's state model. **This is cleaner than Claude Code's hook surface for state classification specifically.**

#### B. The hooks system (since v0.114.0)

Source: [developers.openai.com/codex/hooks](https://developers.openai.com/codex/hooks). Codex hooks are **stable as of v0.124.0 (2026-04-23)**. Available events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`. Configured via `config.toml`. **Command-only — no native HTTP type** (unlike Claude Code).

Means: to push to the dashboard daemon, the hook script is `curl -X POST http://127.0.0.1:7891/hooks/codex/stop -d @-`. Trivial.

### Recommended wiring

- Prefer the **app-server JSON-RPC stream** as primary signal source — it's a real event stream, not script-based.
- Use **hooks** only for events not covered by JSON-RPC notifications (e.g., custom user-defined slash command tracking).
- Correlation key: `thread_id` (Codex's session identifier) + `cwd`.

### What's hard

- App-server is one process per machine, multiple sessions multiplex through it. Dashboard must subscribe once, demultiplex per `thread_id`.
- Initial `initialize` handshake required; mind the `optOutNotificationMethods` parameter to avoid drowning in `agentMessage/delta` if not needed.
- Cross-surface session sync means a thread started in CLI may be resumed in Desktop — dashboard's "is this session live in a Ghostty tab?" needs to track the current attached client, not just the thread.

### Verdict: HIGH

Arguably *better* state observability than Claude Code, because `thread/status/changed` is purpose-built for exactly this.

## Gemini CLI — Signal Quality: MEDIUM

### Available signals

#### A. Hooks system

Source: [geminicli.com/docs/hooks/reference](https://geminicli.com/docs/hooks/reference/). Events:

| Hook event | When it fires | State implication |
|---|---|---|
| `SessionStart` | startup/resume/clear | session registered |
| `SessionEnd` | exit/clear/logout | session removed |
| `BeforeAgent` | After user submission, before planning | running |
| `AfterAgent` | After model generates final response | done |
| `BeforeTool` | Before tool invocation | running, with `tool_name` |
| `AfterTool` | After tool execution | tool done; can detect tests |
| `BeforeModel` / `AfterModel` | LLM request boundary | running deltas |
| `BeforeToolSelection` | Before tool decision | running (advisory) |
| `Notification` | System alerts | possibly awaiting-human (depending on `notification_type`) |
| `PreCompress` | Before history compression | running |

**No native HTTP support.** Hooks run as local subprocesses via stdin/stdout JSON. Same wrapper trick as Codex: a 5-line bash script that `curl`s to the daemon.

**Hooks run synchronously and block the agent loop.** Google docs explicitly warn to keep them fast. `curl` to localhost is fine; anything heavier is dangerous.

#### B. JSONL session files

Source: [Issue #15292](https://github.com/google-gemini/gemini-cli/issues/15292), [DeepWiki Session Management page](https://deepwiki.com/google-gemini/gemini-cli/3.9-session-management).

Sessions are stored as `~/.gemini/tmp/<project_hash>/chats/session-*.jsonl` — append-only JSONL stream. Each line is a `{ type: "user" | "gemini" | "session_metadata" | "tool_call" | ... }` record, written within ~0.75ms of the event. Tail-able.

`<project_hash>` is derived from the project's root directory; the dashboard can pre-compute this hash to map session files to projects.

### What's hard

- **No "permission prompt opened" hook.** Gemini CLI's permission UX is integrated into the agent loop; there's no equivalent of Claude Code's `Notification[matcher=permission_prompt]`. The dashboard can infer "awaiting-human" only via `BeforeTool` for sensitive tools or by observing that `AfterTool` has not fired after a long delay. This is a real gap.
- **No HTTP hooks** — minor, just need wrappers.
- **Hook latency budget is tight** because hooks block the agent loop. Push-async-process-later pattern is mandatory.

### Verdict: MEDIUM

Good enough to detect run/idle/done. Awaiting-human is **inferential**, not direct. Acceptable but the weakest of the three.

## Process-Level Fallbacks (Last Resort)

For all three agents, even if every documented signal fails:

- **PID + parent PTY introspection.** `lsof -p <pid>` reveals the controlling terminal device. macOS `ps` + `ttyS` mapping ties an agent process to a Ghostty tab. Coarse but works.
- **PTY scraping.** `script(1)` or `expect` can attach to a running PTY and capture output. Genuinely a last resort — fragile, breaks when the agent updates its UI library.
- **CPU usage heuristic.** "Process at >10% CPU sustained for 5s = running; idle CPU + no recent stdin = awaiting-human." Crude but provider-agnostic.

These should be **emergency fallbacks**, not the primary signal. The point of the documented hooks/JSON-RPC interfaces is to avoid this.

## Signal Quality Matrix

| Agent | Idle | Running | Awaiting-human | Running-tests | Blocked | Done | Push-based? | Native HTTP? | JSONL tail? |
|---|---|---|---|---|---|---|---|---|---|
| **Claude Code** | High (Stop, TeammateIdle) | High (UserPromptSubmit, PreToolUse) | **High** (Notification[permission_prompt/idle_prompt], PermissionRequest) | Medium (PreToolUse + tool_input.command heuristic) | High (PostToolUseFailure, StopFailure, PermissionDenied) | High (Stop) | Yes | **Yes** (`type: "http"` natively supported) | Yes (`~/.claude/projects/.../<id>.jsonl`) |
| **Codex CLI** | **High** (`thread/status/changed: idle`) | **High** (`thread/status/changed: active`, `turn/started`, `item/started`) | **High** (`item/*/requestApproval`) | Medium (item type `commandExecution` + heuristic) | High (`turn/completed: failed`, `thread/status/changed: systemError`) | High (`turn/completed: completed`) | Yes (JSON-RPC notifications) | Via wrapper (hooks are command-only; JSON-RPC over WebSocket/socket is push) | Yes (transcripts) |
| **Gemini CLI** | Medium (no direct event; infer from AfterAgent + silence) | High (BeforeAgent, BeforeTool, BeforeModel) | **Low–Medium** (no direct hook; infer from BeforeTool + delay) | Medium (BeforeTool + tool_input heuristic) | Medium (no Stop-failure event; infer from missing AfterAgent) | High (AfterAgent) | Yes (hooks) | No (wrap with curl) | Yes (`~/.gemini/tmp/<hash>/chats/session-*.jsonl`) |

## Validated Assumptions

| Assumption | Status | Evidence |
|---|---|---|
| Claude Code hooks fire reliably and an external daemon can listen | Confirmed | 28 documented events; native HTTP hook type; `code.claude.com/docs/en/hooks` |
| Claude Code JSONL is tail-able in real time | Confirmed | `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` schema documented and append-only |
| Codex exposes a JSON-RPC interface a sibling can subscribe to | Confirmed | `codex-rs/app-server/README.md`, Unix socket transport since 2026-04 |
| Gemini CLI has hooks comparable to Claude Code | Partial | Comparable event coverage; **no native HTTP**, no permission-prompt hook |
| All three can be unified into one state model | Confirmed | Mapping table above is complete; awaiting-human is the only weak cell (Gemini) |

## Risks Identified

### 1. Claude Code hook surface might change between versions (Severity: Low)
The hook system is well-documented and Anthropic has been adding events, not removing them. New events are additive. The risk is that field names or matcher syntax shift; pin to specific Claude Code version in the dashboard's tested set.

### 2. Codex `app-server` schema is still evolving (Severity: Medium)
Recent updates added Unix socket support, plugin management, sticky environments. The notification schema is documented but the project moves fast. Wrap the JSON-RPC client in an adapter so changes are localized.

### 3. Gemini "awaiting-human" is inferential, not direct (Severity: Medium)
The dashboard will sometimes show Gemini sessions as "running" when in reality the user has been staring at a permission prompt for 30 seconds. Mitigation: time-based heuristic ("`BeforeTool` fired N seconds ago, no `AfterTool` yet, tool is sensitive -> probably awaiting-human"). Imperfect.

### 4. Hook latency can degrade the agent UX (Severity: Medium)
All three hook systems run hooks synchronously to varying degrees. Slow daemon = slow agent. **The daemon's HTTP handler must respond in < 50ms** (ack the event, queue async work). Treat this as a hard performance budget.

### 5. Multi-session correlation across the same project (Severity: Low)
If the user has two Claude Code sessions in the same `cwd`, the dashboard needs `session_id` (which all events carry) to disambiguate. Already handled by the documented payloads.

### 6. Hooks fire from inside the agent process — auth/permission scoping (Severity: Low)
HTTP hooks pass the local session's environment. Bind the daemon's HTTP server to `127.0.0.1` only. No auth needed if local-only. Document this clearly.

## Open Questions

- [ ] Does Claude Code's `Notification` hook fire reliably *before* the user is shown the prompt, or after? (Determines if "awaiting-human" can be set proactively or only reactively.)
- [ ] What's the actual append rate of Claude Code's JSONL during a heavy turn? (Affects whether `tail -f` is sufficient or if we need inotify/FSEvents.)
- [ ] How does Codex's `thread/status/changed` behave during a long-running approval prompt — does it stay `active` or does it transition to something like `awaitingApproval`? (Verify by inspection.)
- [ ] Can Gemini CLI's `BeforeTool` hook be combined with a watchdog timer in the daemon to confidently flip to "awaiting-human" after, e.g., 5 seconds of no `AfterTool`?
- [ ] What hooks fire when an agent hits a rate-limit / 429? Is there a distinct event vs. `PostToolUseFailure` / `Stop`?

## Recommendations

1. **Build a single normalized event schema** in the daemon. Each hook handler maps the per-agent payload into a `SessionEvent` Pydantic model with fields like `session_id`, `agent`, `cwd`, `event_type`, `tool_name`, `state_hint`. The state machine reads only `SessionEvent`s.

2. **Push, never poll, for state changes.** Polling is a fallback for "current cwd of a Ghostty tab" only. Agent state is purely event-driven.

3. **Treat HTTP hooks as the canonical wiring** for Claude Code; for Codex use the `app-server` Unix socket; for Gemini use a `curl` wrapper script. Document the install steps.

4. **Acknowledge the "awaiting-human" weakness for Gemini upfront.** Set user expectations: Claude Code and Codex have direct signals; Gemini requires a 5-second timeout heuristic.

5. **Build a tiny test harness** that simulates each hook firing (curl-able fixtures) so the daemon can be tested without spinning up real agents. The agents change too often to be a stable test fixture.

6. **Pin tested versions** in CI: Claude Code v2.x.x, Codex v0.124+, Gemini CLI v0.39+. Document in README.

## References

### Claude Code
- [Hooks reference](https://code.claude.com/docs/en/hooks)
- [Agent SDK hooks](https://platform.claude.com/docs/en/agent-sdk/hooks)
- [Hooks production-quality patterns 2026](https://www.pixelmojo.io/blogs/claude-code-hooks-production-quality-ci-cd-patterns)
- [12 lifecycle events guide](https://claudefa.st/blog/tools/hooks/hooks-guide)

### Codex CLI
- [app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- [Cross-Surface Session Sync (April 2026)](https://codex.danielvaughan.com/2026/04/08/cross-surface-session-sync/)
- [Codex Hooks reference](https://developers.openai.com/codex/hooks)
- [Codex CLI hooks "finally here, but still early-stage" review (March 2026)](https://ercanataycom.medium.com/openai-codex-cli-hooks-finally-here-but-still-early-stage-40eb0cabdaca)
- [Codex changelog](https://developers.openai.com/codex/changelog)
- [Codex Exec Server (DeepWiki)](https://deepwiki.com/openai/codex/4.7-exec-server)

### Gemini CLI
- [Hooks reference](https://geminicli.com/docs/hooks/reference/)
- [Hooks overview](https://geminicli.com/docs/hooks/)
- [Hooks DeepWiki](https://deepwiki.com/google-gemini/gemini-cli/5.7-hooks-system)
- [Session management (JSONL chats)](https://geminicli.com/docs/cli/session-management/)
- [Issue #15292 — JSONL migration](https://github.com/google-gemini/gemini-cli/issues/15292)
- [Google Developers Blog: Tailor Gemini CLI to your workflow with hooks](https://developers.googleblog.com/tailor-gemini-cli-to-your-workflow-with-hooks/)
