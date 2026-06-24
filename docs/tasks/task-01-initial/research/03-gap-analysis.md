# Research: Gap Analysis — What Exists vs. What's Missing

**Date:** 2026-04-27
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

The "track CLI subscription usage" half of the user's idea is **well-covered for Claude Code** (ccusage, Claude Code Usage Monitor, claude-code-limit-tracker, phuryn/claude-usage), **partially covered for Codex** (`@ccusage/codex`, tokscale), and **partially covered for Gemini CLI** (tokscale, `/stats`). The "track web subscription usage" half (Claude.ai, ChatGPT.com, Gemini Advanced) is **largely uncovered** in OSS, with only one VS Code extension (jonis100/claude-quota-tracker) and a handful of browser extensions papering over the gap. The "tie usage to a productivity backlog and proactively suggest work" half is **completely uncovered** — no OSS project schedules backlog work as a function of available quota.

The genuine white space is therefore:

1. **A unified personal "quota state" daemon** that aggregates Claude (OAuth + JSONL), Codex (JSON-RPC + JSONL), Gemini (CLI `/stats` + JSON), with a manual-entry fallback for opaque web subscriptions.
2. **Quota-aware scheduling on top of an existing kanban (Vibe Kanban)** or coding-agent dispatcher — surface "you have 38% Claude weekly remaining; here are 3 backlog items sized to fit" as proactive suggestions.

## Coverage Matrix

| Capability | Best existing OSS | Coverage | Gap |
|---|---|---|---|
| Claude Code CLI: token usage from JSONL | **ccusage** (13.2k stars) | ✅ Strong | None |
| Claude Code CLI: real-time quota %, burn-rate, predictions | **Claude Code Usage Monitor**, **claude-code-limit-tracker** | ✅ Good | Hardcoded ceilings drift |
| Claude Code CLI: live OAuth `/api/oauth/usage` poll | None published in active OSS (only Ian Paterson's blog script + jonis100 VS Code ext) | ⚠️ Sparse | No standalone, robust, rate-limit-aware poller |
| Claude.ai web subscription quota | jonis100/claude-quota-tracker (VS Code ext, undocumented APIs) | ⚠️ Single fragile project | No CLI / desktop dashboard equivalent |
| Codex CLI: token usage from JSONL | `@ccusage/codex`, tokscale | ✅ Good | None |
| Codex CLI: live quota via `account/rateLimits/read` | None as standalone tool | ❌ Missing | Need a wrapper that runs `codex app-server` and exposes the JSON-RPC method |
| ChatGPT.com web subscription quota | andyli0123/chatgpt-usage-limit-tracker, Chatterclock (browser only) | ⚠️ Browser-bound | Cross-device blind; no daemon view |
| Gemini CLI: token usage | tokscale, Ian Paterson script | ⚠️ Tokens yes, quota no | No standalone "quota %" view |
| Gemini Advanced web subscription quota | None | ❌ Missing | Provider exposes nothing; only manual entry |
| Multi-provider unified dashboard (web subscriptions) | None | ❌ Missing | Closest: tokscale (CLI tokens), Plexus / LiteLLM (API keys) |
| LLM API observability (pay-as-you-go) | Langfuse, LiteLLM, Helicone (maintenance), Lunary, Phoenix, Portkey, OpenLLMetry, Plexus | ✅ Saturated | Not the user's goal |
| API gateway with subscription-OAuth forwarding | LiteLLM (Claude Code Max + ChatGPT subscription via OAuth) | ⚠️ Partial | Tracks cost, not "quota remaining" |
| Coding-agent task orchestration / kanban | Vibe Kanban, Paperclip, Claude Code Dispatch | ✅ Strong | None of them are quota-aware |
| Cron / scheduled Claude Code execution | claude-code-scheduler, Anthropic Routines | ✅ Good | Fires regardless of quota state |
| Quota-aware backlog suggestion ("you have X capacity, run Y from backlog") | **None found** | ❌ Missing | The user's most distinctive idea |
| AI-task scheduler with capacity awareness | None for personal-LLM-quota sense; Run:ai, Azure quota tooling exist for fleet GPU/API quota in enterprise | ❌ Missing for personal use | Adjacent enterprise tools, wrong audience |

## What's Already Well Covered

### Claude Code local-JSONL analytics

ccusage (and its `@ccusage/codex` sibling) cover ~80% of what a power user needs for retrospective per-session/day/month analytics. Forking would duplicate a maintained, popular project.

### Real-time burn-rate for Claude Code 5-hour windows

Claude Code Usage Monitor does this competently. Predictions, P90 detection, themes, refresh rates are all there.

### Coding-agent orchestration UX

Vibe Kanban (BloopAI) is the kanban-around-coding-agents leader. Don't reinvent.

### LLM API observability

The space is saturated. Don't enter unless you're competing with Langfuse on commercial terms — irrelevant to this personal-use POC.

## What's Partially Covered

### Live Claude.ai web quota

Only jonis100/claude-quota-tracker (VS Code extension) tries it, with the disclaimer that internal APIs may change. It's not packaged as a daemon, CLI, or general-purpose tool.

### Codex / ChatGPT subscription quota

Codex CLI exposes `account/rateLimits/read` over local JSON-RPC, but no OSS project wraps this as a clean reusable signal. Browser extensions cover ChatGPT.com web partially with the cross-device blind spot.

### Gemini CLI quota

Tokscale tracks tokens; nobody exposes Gemini's `/stats` programmatically as a quota signal.

### Multi-provider unification

tokscale is closest — it covers 25+ tools, but for **token counts**, not subscription-quota-percent-remaining. It also gamifies with a global leaderboard, which is anti-private-tracker.

## What's Genuinely Missing (the white space)

### Gap 1 — A "personal AI quota" daemon

A small, local, always-on process that:
- Polls Claude OAuth `/usage` with safe rate-limit handling.
- Spawns and queries Codex `app-server` for `account/rateLimits/read`.
- Reads Gemini CLI `/stats` (or local session JSONs).
- Watches the JSONL/JSON file trees for delta updates without re-parsing entire histories.
- Exposes a unified state (e.g., a JSON over Unix socket, or an MCP tool) like:
  ```json
  {
    "claude":   { "5h_used_pct": 42, "weekly_used_pct": 18, "resets_at": "..."},
    "codex":    { "5h_used_pct": 12, "weekly_used_pct": 25, "resets_at": "..."},
    "gemini":   { "session_tokens": 12000, "daily_used_pct": 8, "ceiling": 1000 }
  }
  ```
- Falls back to manual entry for ChatGPT.com web and Gemini Advanced web.

This is essentially Ian Paterson's blog script productized as an OSS daemon with proper rate-limit hygiene, observability, and a sane interface.

### Gap 2 — A quota-aware backlog/scheduler

Given the daemon in Gap 1, layer on:
- A simple personal backlog (markdown? sqlite? task-master integration?) where each item has an estimated "size" (small / medium / large; or sketched token budget).
- A scheduler / suggester that says "you have X% Claude weekly remaining and 4 days till reset — here are tasks Y, Z that fit."
- Optional autonomous execution: dispatch via Vibe Kanban / claude-code-scheduler / Routines.

**No OSS project found that does this.** The closest analogues are:
- Run:ai over-quota scheduling (enterprise GPU clusters, wrong scale).
- Reclaim/Morgen/Taskade (calendar AI, not "AI's own time").
- Vibe Kanban (manual queue, no quota signal).

### Gap 3 — Web-subscription quota visibility

Genuinely hard. The honest answer is:
- ChatGPT.com Plus/Pro: no API. Best you can do is an extension or manual entry.
- Gemini Advanced: no API. Manual entry only.
- Building this is more product/design problem than engineering.

### Gap 4 — A statusLine-style "quota-everywhere" widget

Across editors / shells / iTerm tab bars / Raycast / macOS menubar. Pieces exist (e.g., `cc-statusline`, Preslav Rachev's macOS toolbar widget) but each is single-provider. A unified menubar/statusline showing all 3-4 quotas is missing.

## Validated Assumptions

| Assumption | Status | Evidence |
|---|---|---|
| Multi-provider personal subscription dashboard exists | Incorrect | None found in OSS; tokscale is per-CLI, jonis100 is Claude-only and VS-Code-bound |
| OSS project ties personal backlog to LLM quota | Incorrect | Vibe Kanban / claude-code-scheduler are quota-blind; no project surfaces "you have capacity, run X" |
| Forking ccusage would solve the user's problem | Incorrect | ccusage covers Claude Code retrospective only; doesn't address web subscriptions or productivity scheduling |
| The space is saturated | Incorrect | API observability is saturated; subscription-quota-aware tooling is sparse, scattered, and partial |

## Risks Identified

### 1. The white space is white because it's hard, not because nobody noticed (Severity: High)

Web-subscription quota visibility is missing not because nobody wants it (the GH issue requests prove they do) but because providers refuse to expose it. Anthropic has closed 6+ requests. OpenAI publishes nothing for ChatGPT.com web. Google publishes nothing for Gemini Advanced web. **Building on undocumented endpoints means living one breaking change away from project death.**

### 2. The audience for "personal multi-LLM quota dashboard" might be small (Severity: High)

Power users heavy enough to care about quota typically (a) consolidate on one provider's Max plan, or (b) don't have time to install a daemon. The intersection of "uses 3+ paid AI subscriptions heavily, manages a structured backlog, wants automation, will install/configure local tooling" is narrow. Possibly a few thousand users globally — fine for an OSS hobby project, weak for a commercial play.

### 3. Productivity-suggestion UX is the actual hard problem (Severity: Medium)

Even with perfect quota data, "suggest a project from backlog when capacity is available" requires:
- A real personal backlog system (most users don't keep one structured).
- Reasonable estimates of "how much this task will cost" (notoriously hard).
- A motivation model (will the user actually act on the suggestion, or ignore it?).
- A non-creepy notification UX.

### 4. Anthropic / OpenAI / Google may roll out their own (Severity: Medium)

If Anthropic finally exposes `/usage` in statusLine JSON (community wants it badly), most of the Claude side becomes trivial overnight. The product moat would shrink. Same for OpenAI/Google adding subscription dashboards.

### 5. Rate-limit poisoning (Severity: Medium — operational)

If many users adopt a tool that hits `api.anthropic.com/api/oauth/usage`, Anthropic will tighten the rate limit further (already aggressive). The collective action problem could break the tool for everyone.

## Open Questions

- [ ] How many users (within Anthropic Max + ChatGPT Pro + Google AI Pro three-subscription cohort) actually run out of quota mid-cycle? Anecdotally yes, but data?
- [ ] Is there a meaningful overlap between "people who maintain backlogs" and "people who hit AI quota limits"?
- [ ] Would users prefer a quota-aware dispatcher (auto-runs from backlog) or a quota-aware suggester (asks them what to run)?
- [ ] Is there an MCP-shaped solution that lets quota state become a tool that any AI agent can consult during planning ("how much capacity do I have today")?

## Recommendations

### Proceed With (recommended scope)

A **focused, narrow POC** built in two layers:

**Layer 1 — Quota daemon (real, defensible value):**
- Pluggable providers: `claude_code_jsonl`, `claude_oauth_usage`, `codex_app_server`, `codex_jsonl`, `gemini_cli_stats`, `gemini_jsonl`, `manual_entry` (for web subs).
- Local-only Pydantic-based state model. Sqlite for history.
- Single CLI entry: `aiquota status` → prints per-provider quota %.
- Optional MCP server façade.

**Layer 2 — Backlog + suggester (more speculative):**
- Markdown or SQLite backlog with size estimates.
- `aiquota suggest` → "Based on remaining quota, you can run: ..."
- Integration adapter to Vibe Kanban / claude-code-scheduler so suggestions can become dispatched runs.

This is a cohesive product, but **Layer 2 is the speculative half** — validate Layer 1 first, ship it standalone, see if anyone uses it, then build Layer 2 only on real demand.

### Avoid

- Trying to displace ccusage / tokscale / Claude Code Usage Monitor on their established turf.
- Building a SaaS — local-first only. Tokens/cookies must never leave the machine.
- Unrealistic web-scraping ambitions for ChatGPT.com / Gemini Advanced.
- Building a yet-another LLM API observability platform.

### Consider (lower-risk alternative)

A **single contribution to ccusage** that adds a `--live-quota` mode pulling from Anthropic's OAuth endpoint (with proper rate-limit handling), plus a `gemini` sister-package and an explicit "merge" command. Ship into an existing 13.2k-star project rather than competing.

A **second, separate** MCP server: `quota-mcp` that exposes "current available quota per provider" as a tool. Any agent (Claude Code itself, custom dispatcher, Vibe Kanban) can call it. Tiny, focused, valuable.

## References

- All sources cited in 01-oss-landscape.md and 02-provider-data-availability.md.
