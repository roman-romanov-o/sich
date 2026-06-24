# Research: OSS Landscape — Subscription-Quota Tracking and Productive-Use Tools

**Date:** 2026-04-27
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

The OSS landscape splits cleanly into two camps: (1) a thriving ecosystem of **CLI-coding-agent quota trackers** (ccusage, tokscale, Claude Code Usage Monitor, claude-code-limit-tracker, jonis100/claude-quota-tracker, phuryn/claude-usage) that read local JSONL session files to compute Claude Code / Codex / Gemini CLI usage against subscription windows, and (2) the well-funded **API observability** stack (Helicone, Langfuse, LiteLLM, Lunary, OpenLIT, Phoenix, Portkey, OpenRouter) that tracks spend on pay-as-you-go API keys but is essentially blind to web-chat subscription quotas. **No project found unifies subscription-quota tracking across Claude.ai + ChatGPT Plus + Gemini Advanced web subscriptions in one personal dashboard, and no project ties available quota to a personal task backlog.** The closest precedent is one personal blog script (Ian Paterson's ~250-line "tracking-claude-codex-gemini-quotas-from-one-script") that aggregates three CLIs but is not published as OSS.

## Research Questions

1. Which OSS tools track per-provider AI usage, and do they target subscription quota or API spend?
2. Which tools cover multiple providers in one place?
3. Does anything connect "available quota" to "things to run from a backlog"?

## Category A — CLI-Agent Quota Trackers (Local JSONL Readers)

These read locally written transcript files (Claude Code: `~/.claude/projects/<encoded-cwd>/*.jsonl`; Codex: similar JSONL; Gemini: `~/.gemini/tmp/<project_hash>/chats/`). They compute usage against published plan limits and approximate "messages remaining" without calling provider APIs. **They cover the CLI-against-subscription path only**, not Claude.ai/ChatGPT.com/gemini.google.com web usage.

### 1. ccusage — `ryoppippi/ccusage` (~13.2k stars)

**URL:** <https://github.com/ryoppippi/ccusage>, <https://ccusage.com/>

- Reads Claude Code JSONL session files from `~/.claude/projects/`.
- Reports daily / monthly / per-session / 5-hour-window token spend.
- **API-pricing-based cost calculator**, not a subscription-quota tracker. It tells you "you spent $X equivalent" — not "you have N% of your weekly quota left."
- Sister packages: `@ccusage/codex` (OpenAI Codex CLI), `@ccusage/opencode`, `@ccusage/pi`, `@ccusage/amp`. **No Gemini package.**
- Limitation: no live call to Anthropic, no awareness of the 5-hour rolling subscription window other than what it can derive from local logs; cannot see usage from non-CLI sources (Claude.ai web, Cowork sessions which are server-side).

### 2. tokscale — `junhoyeo/tokscale`

**URL:** <https://github.com/junhoyeo/tokscale>

- Tracks **25+ AI coding assistants** including OpenCode, Claude Code, Codex CLI, GitHub Copilot CLI, Cursor IDE, Gemini CLI, Amp, Codebuff, Factory Droid, Hermes, Pi, Kimi, Qwen, Roo Code, Kilo, Goose, Antigravity, Synthetic.
- Native Rust core, ~10x faster than JS competitors.
- Reads from SQLite DBs, JSONL files, JSON arrays, and (for Cursor) authenticated session-token API sync.
- Tracks **input / output / cache read/write / reasoning tokens** with LiteLLM pricing data.
- **No subscription-quota awareness** — it's purely token consumption + cost calc. Includes a global leaderboard (gamification) which is the opposite of "private quota dashboard."

### 3. Claude Code Usage Monitor — `Maciek-roboblog/Claude-Code-Usage-Monitor`

**URL:** <https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor>

- **Closest match to the user's "track quota in real time" goal** for the Claude Code path.
- Hardcodes plan ceilings: Pro ~19k, Max5 ~88k, Max20 ~220k tokens per 5-hour window. Auto-detects "Custom" plan when usage exceeds Pro thresholds.
- Burn-rate analytics, P90 percentile limit detection, predicted exhaustion time for the current 5-hour session.
- Multi-view: realtime, daily, monthly.
- Limitation: hardcoded limits become stale when Anthropic changes them (which they do — limits "fluctuate based on demand"); does not see Claude.ai web usage.

### 4. claude-code-limit-tracker — `TylerGallenbeck/claude-code-limit-tracker`

**URL:** <https://github.com/TylerGallenbeck/claude-code-limit-tracker>

- Status-line integration. Tracks **two separate limits**: 5-hour rolling prompt count and weekly conversation hours, broken down per model (Sonnet vs. Opus).
- Hardcoded subscription limits per tier (Free / Pro / Max5 / Max20).
- Analyzes `~/.claude/projects/` conversation files; does not query Anthropic directly.
- "Actual conversation hours, not estimates" — competes with Anthropic's own internal counters.

### 5. claude-usage — `phuryn/claude-usage`

**URL:** <https://github.com/phuryn/claude-usage>

- Local Flask-style dashboard at `localhost:8080`, populates a SQLite DB from JSONL parsing.
- "Pro and Max subscribers get a progress bar" — but README does not document where the quota ceiling number comes from (likely hardcoded).
- Explicit caveat: **Cowork sessions are not captured** (they run server-side without writing local JSONL). This is a structural blind spot for any local-reader approach.

### 6. claude-quota-tracker — `jonis100/claude-quota-tracker`

**URL:** <https://github.com/jonis100/claude-quota-tracker>

- VS Code extension, **only project that reverse-engineers an internal Anthropic endpoint to fetch true quota state**.
- Authenticates with Claude.ai using browser session credentials; fetches 5-hour and 7-day window usage from internal endpoints.
- Documented disclaimer: "relies on unofficial, undocumented Claude.ai internal APIs and browser session cookies. Anthropic may change or remove these at any time."
- This is the design pattern that actually answers "what's my real Claude.ai quota right now" — but it's fragile and only one provider.

### 7. ChatGPT Usage Limit Tracker — `andyli0123/chatgpt-usage-limit-tracker`

**URL:** <https://github.com/andyli0123/chatgpt-usage-limit-tracker> (Chrome + Firefox)

- Listens for requests to ChatGPT's backend API in the browser, classifies model, increments a local counter, compares against plan-specific limits.
- Supports gpt-5, gpt-5-thinking, gpt-5-pro; plan switcher Free/Plus/Team/Pro.
- All data local; no external transmission.
- Limitation: it **counts requests it observes**; if you use ChatGPT from another browser/device/CLI, those don't count. Plan limits hardcoded.

### 8. Chatterclock — Chrome extension

**URL:** Chrome Web Store listing `mepflplnjbngmgakdefimlgbfpmhonoj`

- Lighter-weight alternative; per-model totals for the matching ChatGPT windows (3-hour for gpt-5, weekly for gpt-5-thinking).
- Closed-source / store-only, included for completeness.

### 9. DeepMeter — Chrome Web Store

- ChatGPT usage tracker with focus on Deep Research credits. Closed-source store extension.

### 10. Ian Paterson's "one script" approach (blog post, not published)

**URL:** <https://ianlpaterson.com/blog/tracking-claude-codex-gemini-quotas-from-one-script/>

- ~250 lines of bash + Python + JS, runs hourly via cron, writes a unified JSON.
- **Claude Code:** calls undocumented `https://api.anthropic.com/api/oauth/usage` with OAuth creds from `~/.claude/.credentials.json`.
- **Codex:** uses Codex `app-server` JSON-RPC method `account/rateLimits/read`.
- **Gemini:** parses `~/.gemini/tmp/_/chats/session-*.json` and counts records (no official quota API exists for free tier).
- **Author has not open-sourced it.** This is the architectural blueprint someone needs to ship as a real OSS project.

## Category B — API Observability / LLM Gateway (NOT Subscription-Quota)

These all assume you bring an API key and want to track pay-as-you-go spend. They are not relevant to the user's "subscription quota" goal except as inspiration for dashboard UX.

### Helicone

- Open-source proxy that sits in front of LLM API endpoints; logs requests / tokens / cost.
- **Status update (important):** Helicone has been acquired by Mintlify and moved to maintenance mode. Langfuse is publishing migration guides.
- Tracks API spend only, not subscription quota.

### Langfuse (MIT)

- Most-used OSS LLM observability platform; tracing, prompt management, evaluations.
- SDK-based, PostgreSQL backend.
- Self-hostable; cloud free tier 50k events/month.
- API spend + traces, not subscription quota.

### LiteLLM (BerriAI/litellm)

- Python SDK + proxy (AI Gateway) for 100+ LLM providers.
- **Has explicit Claude Code Max subscription support** via OAuth token forwarding (`forward_client_headers_to_llm_api: true`) — routes Max-subscription Claude Code traffic through the gateway with per-user OAuth.
- **Has ChatGPT subscription provider** via OAuth device-code flow.
- Tracks **cost** (USD) per virtual key, with budgets and rate limits — but the docs explicitly note it tracks cost-equivalent, not "remaining subscription messages." It strips `max_tokens`/`max_output_tokens` for the ChatGPT subscription provider because the backend rejects them.
- Closest precedent for "single gateway in front of multiple subscriptions," but designed for team/enterprise spend governance rather than personal quota visibility.

### Lunary, OpenLIT, OpenLLMetry/Traceloop, Phoenix (Arize), Portkey, OpenRouter, Plexus (`mcowger/plexus`)

- All API-side. Portkey enforces budgets/quotas on virtual keys; OpenRouter is a paid-credit reseller with per-key rate limits; Plexus is per-API-key quota tracking with OAuth provider support but no subscription-quota concept.
- None of these answer "how much of my Claude Pro weekly cap have I used."

## Category C — Productivity / Backlog-Driven Agent Orchestration

This is the user's second goal: tie quota to a backlog and proactively suggest work. The OSS that exists here is **agent orchestration** without quota awareness.

### Vibe Kanban — `BloopAI/vibe-kanban`

**URL:** <https://github.com/BloopAI/vibe-kanban>, <https://vibekanban.com/>

- Kanban board UI wrapping Claude Code / Codex / Cursor / Copilot / Gemini coding agents.
- Queue tasks → agents work in parallel in isolated git worktrees → reviewer (human) approves diffs.
- Implements MCP both as client and server.
- **No quota awareness.** It schedules by user choice and parallelism, not by available subscription capacity.

### Claude Code Scheduler — `jshchnz/claude-code-scheduler`

**URL:** <https://github.com/jshchnz/claude-code-scheduler>

- Plugin for Claude Code; cron-based / launchd-based scheduled `claude -p "<prompt>"` execution.
- Natural-language schedules ("every weekday 9am"), git worktree isolation.
- **No quota awareness.** Will happily fire a task when you have 0% quota left.

### Anthropic Claude Code Routines (Anthropic-built, not OSS)

- Cloud-side scheduled headless agents (Max plan only).
- Charged at standard inference rates; the article hints these consume subscription tokens.
- Not a community project; included as competitive context.

### Paperclip, Claude Code Dispatch

- Vibe Kanban competitors. Same gap: no quota-aware scheduling.

### General "AI task management" tools (Morgen, Reclaim, Taskade, FlowSavvy)

- Calendar / to-do AI assistants. They use AI to schedule **your** time; they don't schedule **AI's** time against quota. Off-target.

## Category D — Closed-Source / Web Subscription UIs (For Context)

- **Claude Code `/usage` REPL command**: shows session %, weekly %, extra-usage balance — but **the data is NOT exposed in the statusLine JSON payload**. There are at least 6 open feature requests asking Anthropic to surface this; the top one (#22428, #28999, #27829, #27915, #27636, #20413) is consistently closed as "duplicate" or "not planned." Anthropic has explicitly chosen not to expose this in a tool-usable format.
- **Gemini CLI `/stats model` and `/stats`**: shows token usage and quota for the current session.
- **Codex CLI `/status`**: shows remaining limits for the active session.
- **`https://claude.ai/settings/usage`**: human-only dashboard, Cloudflare-protected against scraping.

## Validated Assumptions

| Assumption | Status | Evidence |
|------------|--------|----------|
| OSS tools exist that track Claude Code subscription usage from JSONL | Confirmed | ccusage, Claude-Code-Usage-Monitor, claude-code-limit-tracker, phuryn/claude-usage all do this |
| Some OSS tool already covers Claude + ChatGPT + Gemini in one personal dashboard | Incorrect | tokscale comes closest for CLI agents but is token-counting not quota-aware; only Ian Paterson's unpublished script combines all three quota states |
| Subscription providers expose programmatic per-user quota | Partial | Anthropic has `api.anthropic.com/api/oauth/usage` (undocumented, OAuth-only, aggressively rate-limited); OpenAI Codex exposes `account/rateLimits/read` over local JSON-RPC; Gemini has `/stats` in CLI but no remote API; web subscriptions have no public endpoint |
| LiteLLM/Helicone-style observability covers subscription quotas | Incorrect | All track API-key pay-as-you-go cost; LiteLLM has Claude Code Max OAuth support but exposes cost, not "messages remaining" |
| There's an OSS quota-aware task scheduler that picks backlog work based on capacity | Incorrect | Vibe Kanban, claude-code-scheduler, Paperclip all schedule blindly with respect to quota |

## Risks Identified

### 1. Endpoint fragility (Severity: High)

The only known way to get **true** Claude.ai subscription quota is the undocumented `api.anthropic.com/api/oauth/usage` endpoint. GitHub issue #31637 reports it is "aggressively rate-limited; no `Retry-After` header; gets stuck in 429 loops for 30+ minutes." Anthropic actively discourages dashboard polling. Building on this is building on sand. Multiple tools (jonis100/claude-quota-tracker, codelynx blog) explicitly disclaim this.

### 2. ChatGPT web subscription has no API at all (Severity: High)

OpenAI does not expose ChatGPT Plus/Pro web-UI usage anywhere. The only existing approach is browser-extension request interception, which sees only what happens in that browser. A user who hits ChatGPT from desktop app + mobile + web from two devices will never see correct totals.

### 3. Gemini Advanced (web) similarly opaque (Severity: High)

Gemini CLI exposes `/stats`. Gemini Advanced web subscription does not. Gemini App Help docs only describe limits qualitatively ("Thinking and Pro have usage limits that increase with subscription").

### 4. Cowork / cloud-side sessions invisible to local readers (Severity: Medium)

`phuryn/claude-usage` README explicitly states Cowork sessions don't write local JSONL. As Anthropic moves more execution server-side (Routines, Cowork, Chyros), local-JSONL-reading tools see less of total usage.

### 5. Hardcoded plan limits (Severity: Medium)

Every project that fakes "% remaining" hardcodes thresholds (45 msg / 5h Pro, 225 / Max5, 900 / Max20). Anthropic explicitly states limits "fluctuate based on demand." Hardcoded values silently drift to wrong.

### 6. Helicone moved to maintenance mode (Severity: Low — context)

The proxy-based observability category is consolidating around Langfuse. Don't fork Helicone.

## Open Questions

- [ ] Does the Anthropic OAuth `/usage` endpoint return the same numbers as the in-app `/usage` REPL command? (Worth verifying empirically with the user's own credentials.)
- [ ] Does `account/rateLimits/read` from Codex `app-server` cover only Codex or all ChatGPT subscription windows? (Probably Codex-only per OpenAI docs.)
- [ ] Are Cowork sessions' usage at least reflected in the OAuth `/usage` endpoint even if not locally?
- [ ] What does Anthropic's Admin/Usage Cost API expose for **subscription** users vs. API users? (Docs imply API-only, but confirm.)

## Recommendations

### Don't fork

ccusage already owns the Claude Code local JSONL niche; it has 13.2k stars and a published sister-package architecture. Forking it for this idea would be duplicating their work for the CLI-only path. Use it as a library if anything.

### Do consider

1. A **personal aggregator daemon** (Ian Paterson's blueprint, productized) is genuinely missing OSS:
   - Pull Claude.ai quota from `api.anthropic.com/api/oauth/usage` (with conservative polling and graceful 429 handling).
   - Pull Codex from `account/rateLimits/read` JSON-RPC.
   - Read Claude Code / Codex / Gemini CLI JSONL for richer per-model breakdown.
   - Optionally accept manual entry for ChatGPT-Plus and Gemini-Advanced web (no API exists).
2. **A quota-aware scheduler layer on top of Vibe Kanban / claude-code-scheduler.** The orchestration UX is solved; quota-awareness is not. An MCP server that exposes "current available quota per provider" to a kanban tool is a much smaller, more focused contribution than another full kanban.

### Avoid

- Building a new full LLM observability platform (Langfuse won that).
- Building a new Claude-Code-only JSONL reader (ccusage won that).
- Relying on web scraping of `claude.ai/settings/usage` (Cloudflare blocks it).
- Hardcoding plan ceilings without a runtime override mechanism — Anthropic changes them.

## References

- ccusage: <https://github.com/ryoppippi/ccusage> · <https://ccusage.com/>
- tokscale: <https://github.com/junhoyeo/tokscale>
- Claude Code Usage Monitor: <https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor>
- claude-code-limit-tracker: <https://github.com/TylerGallenbeck/claude-code-limit-tracker>
- claude-usage: <https://github.com/phuryn/claude-usage>
- claude-quota-tracker: <https://github.com/jonis100/claude-quota-tracker>
- chatgpt-usage-limit-tracker: <https://github.com/andyli0123/chatgpt-usage-limit-tracker>
- Ian Paterson, three-quota script: <https://ianlpaterson.com/blog/tracking-claude-codex-gemini-quotas-from-one-script/>
- LiteLLM Claude Code Max: <https://docs.litellm.ai/docs/tutorials/claude_code_max_subscription>
- LiteLLM ChatGPT subscription: <https://docs.litellm.ai/docs/providers/chatgpt>
- Plexus: <https://github.com/mcowger/plexus>
- Vibe Kanban: <https://github.com/BloopAI/vibe-kanban>
- Claude Code Scheduler: <https://github.com/jshchnz/claude-code-scheduler>
- Anthropic feature requests for statusLine quota: GH issues #22428, #27829, #28999, #27915, #27636, #20413, #18121
- OAuth `/usage` rate-limit issue: <https://github.com/anthropics/claude-code/issues/31637>
- Codex app-server README: <https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md>
- Inside Claude Code session format: <https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b>
- Gemini CLI quota: <https://geminicli.com/docs/resources/quota-and-pricing/>
