# Research: Provider Data Availability — What Each Subscription Exposes

**Date:** 2026-04-27
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

Anthropic, OpenAI, and Google each expose **subscription** quota data through markedly different mechanisms, and none of them are first-class public APIs. Anthropic has an **undocumented OAuth endpoint** that is heavily rate-limited; OpenAI exposes Codex limits via a **local JSON-RPC interface** in Codex CLI's `app-server`, but offers nothing for the ChatGPT.com web subscription; Google exposes nothing remotely for Gemini Advanced web, and surfaces Gemini CLI session usage only via the local `/stats` REPL command. **Local CLI JSONL files are the most reliable common signal** across providers — but they cover only what the CLI saw, missing web-UI and cloud-side (Cowork, Routines) usage.

## Provider 1 — Anthropic (Claude)

### Subscription Plans (2026)

- **Pro** ($20/mo): ~45 messages per rolling 5-hour window; weekly cap added Aug 2025; ~200-216 daily messages with distributed usage.
- **Max 5x** (~$100/mo): ~225 messages / 5h; weekly cap shared across Claude + Claude Code.
- **Max 20x** (~$200/mo): ~900 messages / 5h.
- All limits explicitly **fluctuate based on demand** and are not contractual.
- Two separate quotas to track: 5-hour rolling window + 7-day weekly window.
- Weekly limit is shared across **all Claude.ai usage AND Claude Code usage** — they're one bucket. This makes per-channel attribution important if you want to know "what burned my quota."

### Programmatic surfaces

#### a) Undocumented OAuth usage endpoint

- URL: `https://api.anthropic.com/api/oauth/usage`
- Auth: Bearer with OAuth credential (token starting with `sk-ant-oat01-`), found in `~/.claude/.credentials.json`
- Beta header: `anthropic-beta: oauth-2025-04-20`
- This is what Claude Code's own statusline HUD calls.
- **Aggressively rate-limited**: GH issue #31637 documents 429 lockouts after low-frequency polling, no `Retry-After` header, persistent stuck states for 30+ minutes. Polling at <60s intervals is unsafe; even 5-minute polls trigger lockouts in some users.
- **Not in the public API reference** — usage subject to change without notice.

#### b) Claude Code `/usage` REPL command

- Shows session %, weekly %, extra-usage balance.
- **Not exposed in statusLine JSON payload** — Anthropic has closed at least 6 feature requests (GH #22428, #28999, #27829, #27915, #27636, #20413) asking for this; latest known status is "not planned" / "duplicate."
- Means: programmatic consumption requires either (1) the OAuth endpoint above, or (2) parsing local JSONL.

#### c) Local Claude Code JSONL session files

- Path: `~/.claude/projects/<url-encoded-cwd>/<session-uuid>.jsonl`
- One JSON object per line; assistant messages contain `message.usage` with concrete fields:
  ```json
  {
    "input_tokens": 12840,
    "output_tokens": 631,
    "cache_read_input_tokens": 8200,
    "cache_creation": {
      "ephemeral_5m_input_tokens": 3600,
      "ephemeral_1h_input_tokens": 0
    }
  }
  ```
- Plus `model` (e.g. `claude-opus-4-5-20251101`), `timestamp`, `sessionId`, `cwd`, `parentUuid`.
- **Blind to:** Claude.ai web sessions, Cowork sessions (server-side, no local JSONL), Anthropic-side Routines.
- **Reliable for:** local Claude Code activity only.

#### d) Anthropic Admin / Usage & Cost API

- `https://platform.claude.com/docs/en/build-with-claude/usage-cost-api`
- `/v1/organizations/usage_report/messages` returns historical token usage by model / workspace / service tier.
- **Pay-as-you-go API only** — does not return data for Claude Pro / Max subscription users. Does not solve this problem.

#### e) Web scraping `claude.ai/settings/usage`

- Cloudflare bot protection blocks scraping. Confirmed by feature-request authors who tried it.

### Practical conclusion (Claude)

Use `/api/oauth/usage` polled **at most every 5–10 minutes with hard backoff on 429**, plus local JSONL parsing for richer per-model and per-project breakdown. Be ready for the OAuth endpoint to break.

---

## Provider 2 — OpenAI (ChatGPT + Codex)

### Subscription Plans (2026)

- **ChatGPT Plus / Go** ($20/mo): ~150 GPT-4o msgs per rolling 3-hour window; o3 100/week; o4-mini 300/day; o4-mini-high 100/day; image generation 50 per 3h.
- **ChatGPT Pro** ($200/mo): ~3,000 GPT-5.2 Thinking msgs / week, etc. — limits dynamic.
- Codex CLI consumes ChatGPT plan quota via a separate but related limit system: 5-hour windows + weekly caps; "messages" measured in size/complexity, not fixed counts.
- Pro promo: 2x Codex usage through May 31, 2026; Plus 25x instead of 20x.

### Programmatic surfaces

#### a) Codex CLI `app-server` JSON-RPC

- Source: <https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md>
- JSON-RPC 2.0 over stdio / WebSocket / Unix socket.
- Method: `account/rateLimits/read` — returns:
  - `usedPercent`
  - `windowDurationMins`
  - `resetsAt` (Unix timestamp)
  - `rateLimitReachedType` (set when limit reached)
- Plus `thread/goal/set` (clients can set token budgets) and `thread/tokenUsage/updated` notifications during a turn.
- **Officially documented (sort of)** — README is in the public repo, but the API is positioned for "rich UIs like the VS Code extension," and `clientInfo.name` is logged for OpenAI compliance. Not a public REST API; runs locally only.
- Practical use: spawn `codex app-server`, JSON-RPC `account/rateLimits/read` periodically.

#### b) Codex CLI `/status` REPL

- Same data as the JSON-RPC method, presented to humans.

#### c) Local Codex JSONL session files

- Codex writes JSONL transcripts similar to Claude Code. `@ccusage/codex` reads them.
- Token usage per turn available; same blind spot (only what Codex CLI saw).

#### d) ChatGPT.com web — `/backend-api/wham/usage` endpoint

- Mentioned in third-party article (knightli.com/2026/04/12/codex-usage-quota-check). Returns Codex quota + reset times.
- Authenticated with browser session cookie. Same fragility profile as Anthropic OAuth endpoint — undocumented, can change.

#### e) ChatGPT.com web subscription

- **No official API for Plus/Pro web message counters.** Period.
- Only path: browser extension intercepts requests as they happen (e.g., andyli0123/chatgpt-usage-limit-tracker, Chatterclock).
- Means: the system **cannot know about messages sent from the official ChatGPT desktop app or mobile** unless an extension is installed in the same browser. Cross-device usage is invisible.

#### f) OpenAI Admin / Usage API

- `platform.openai.com/usage` tracks **API usage only**, not ChatGPT subscription. Same pattern as Anthropic.

### Practical conclusion (OpenAI)

For Codex CLI: `account/rateLimits/read` via local JSON-RPC is the cleanest signal. For ChatGPT.com web: there is no good answer; either (a) install a browser extension and accept blind spots, (b) call `/backend-api/wham/usage` with the user's session cookie (fragile, breaks logged-out states), or (c) accept manual entry.

---

## Provider 3 — Google (Gemini)

### Subscription Plans (2026)

- **Google AI Pro** ($19.99/mo): higher Gemini Apps limits; access to Nano Banana Pro and Gemini Pro models; higher quotas in Gemini CLI / Code Assist / Antigravity / Jules.
- **Google AI Ultra** ($249.99/mo): the headline tier.
- Gemini CLI free tier: 60 req/min, 1,000 req/day with personal Google account; from March 25, 2026 free Pro models are paid-only.
- Gemini Code Assist individual tier: 1,000 req/day.
- Gemini API key (free): 250 req/day. Workspace: 1,500-2,000/day.

### Programmatic surfaces

#### a) Gemini CLI `/stats` and `/stats model` REPL

- Shows current session token usage and "limits associated with your current quota."
- End-of-session summary printed automatically.
- Local-only output; no remote API equivalent for the CLI quota state.

#### b) Local Gemini CLI session files

- Path: `~/.gemini/tmp/<project_hash>/chats/session-*.json`
- JSON format (not JSONL); contains token usage stats (input, output, cached) and assistant reasoning summaries.
- Ian Paterson's script counts records here as a quota proxy because no quota API exists.
- Configuration via `~/.gemini/settings.json`.

#### c) Gemini API

- Has rate limits visible only in Google AI Studio dashboard. Pay-as-you-go.
- **Important asymmetry**: a paid Gemini Advanced web subscription does NOT translate to API quota. Confirmed in Google's own AI Developer Forum: "Pro subscription vs API Quota 0 (Resource Exhausted)." The web subscription and the API are entirely separate billing realms.

#### d) Vertex AI

- Express Mode has variable limits.
- Workspace tiers up to 1.5-2k req/day.

#### e) Gemini Advanced web — `gemini.google.com`

- **No public quota API.** Google support docs describe limits only qualitatively ("Thinking and Pro have usage limits that increase with subscription plans").
- No prominent OSS browser extension equivalent to ChatGPT trackers exists for Gemini.

### Practical conclusion (Gemini)

Gemini CLI is reasonably tractable via local session files + `/stats`. Gemini Advanced web is essentially **invisible to any tooling** today — the only quota signal is "did the UI block me?" Manual entry is the realistic option for the web side.

---

## Cross-Provider Surface Comparison

| Provider | Subscription quota API | Local data | CLI quota command | Web scraping viable | Notes |
|---|---|---|---|---|---|
| Claude.ai | Undocumented `/api/oauth/usage` (heavily rate-limited) | Claude Code JSONL only | `/usage` REPL (not in statusLine JSON) | No (Cloudflare) | Weekly bucket shared with Claude Code |
| ChatGPT.com | None for web; `account/rateLimits/read` for Codex local | Codex JSONL | `/status` in Codex; nothing on ChatGPT.com | Possible via session cookie, fragile | Cross-device invisible without extension |
| Gemini Advanced | None | Gemini CLI `~/.gemini/tmp/.../chats/session-*.json` | `/stats`, `/stats model` | No prominent attempts | Web-subscription quota essentially opaque |

## Validated Assumptions

| Assumption | Status | Evidence |
|---|---|---|
| Subscription providers expose per-user usage data programmatically | Partial | Only Anthropic (undocumented, fragile) and OpenAI Codex (local JSON-RPC, Codex-only) |
| Claude Code JSONL files always contain token usage per turn | Confirmed | Documented schema; `message.usage.{input_tokens, output_tokens, cache_read_input_tokens, cache_creation}` |
| Claude Code statusLine receives quota info | Incorrect | Anthropic has closed multiple requests asking for this; users must call OAuth endpoint manually |
| ChatGPT Plus has any official usage API | Incorrect | OpenAI's usage dashboard is API-only; the only known endpoint `/backend-api/wham/usage` is undocumented and Codex-flavored |
| Gemini Advanced web exposes quota | Incorrect | No API, no extension, only qualitative help docs |
| Web scraping `claude.ai/settings/usage` is feasible | Incorrect | Cloudflare bot protection blocks it (confirmed by feature-request authors) |
| Local CLI JSONLs cover all subscription usage | Incorrect | Web sessions, Cowork, Anthropic-side Routines, mobile apps, desktop apps are all blind spots |

## Risks Identified

### 1. Vendor breakage of undocumented endpoints (Severity: High)

`api.anthropic.com/api/oauth/usage` and OpenAI's `/backend-api/wham/usage` can disappear at any time. Anthropic has actively closed feature requests to **make this data official** — signal that they don't want third-party tooling building on it.

**Mitigation:** Treat these as best-effort optional signals. Have a "manual entry" fallback path.

### 2. Web subscription invisibility (Severity: High)

If the user does most of their AI work in the official ChatGPT desktop app and the gemini.google.com web UI, **no current technique can measure that usage from outside.** The system would only ever see CLI / browser-extension activity.

**Mitigation:** Either commit to "this tool is for CLI-heavy users" (narrow audience) or accept a manual-entry workflow for web-heavy users (poor UX).

### 3. Hardcoded ceilings drift (Severity: Medium)

Every provider says limits "fluctuate based on demand." Tools that hardcode `45 msg / 5h` for Pro will silently report wrong percentages over time.

**Mitigation:** Pull ceilings from authoritative sources where possible (`/stats` in Gemini CLI gives current limits; OAuth endpoint may include them); allow user override.

### 4. Cloud-side execution growth (Severity: Medium)

Anthropic Cowork, Routines, and rumored Chyros all run server-side without local JSONL. As Anthropic pushes more agentic execution to cloud, JSONL-reading tools see less of total usage.

**Mitigation:** Prefer the OAuth endpoint (which presumably reflects all usage) over JSONL-only readers, despite the rate-limit pain.

### 5. Authentication token exposure (Severity: Medium)

OAuth credentials in `~/.claude/.credentials.json` and ChatGPT session cookies are sensitive. Any tool that reads them must keep them local; never log, never transmit.

**Mitigation:** Architect as a local daemon. No "send your tokens to our SaaS." Document `~/.claude/.credentials.json` is sensitive.

### 6. Subscription/API quota are separate realms (Severity: Low — design clarity)

Especially Google: paid Gemini Advanced does NOT grant API quota; they're separate billing realms. The user's mental model "I pay for Gemini Advanced so I have credits" is wrong for API calls.

**Mitigation:** Clearly distinguish "subscription quota" from "API spend" in any UI; don't try to unify them.

## Open Questions

- [ ] Does Anthropic's `/api/oauth/usage` reflect Cowork and Routines usage, or only direct CLI/web?
- [ ] What's the actual rate limit on `/api/oauth/usage`? (No documentation; only failed-poll reports.)
- [ ] Does Codex `account/rateLimits/read` cover full ChatGPT plan usage, or only Codex CLI's slice?
- [ ] Is there a `chatgpt.com/backend-api/conversation_limits` (or similar) endpoint reachable with session cookie that returns the same data the in-UI badge shows?
- [ ] For Gemini, does Google publish quota data anywhere in `myaccount.google.com` or `aistudio.google.com` reachable with OAuth?
- [ ] Are there OpenTelemetry hooks in newer Claude Code / Codex / Gemini CLI versions that could be leveraged instead of JSONL parsing?

## Recommendations

### Proceed With

1. **Local JSONL parser** for Claude Code, Codex, Gemini CLI as foundation — this is the most reliable common signal.
2. **OAuth `/usage` poller for Claude** with hard 5-minute floor, exponential backoff to 30 min on 429, and a circuit breaker after 3 consecutive failures.
3. **Codex `app-server` JSON-RPC** for OpenAI Codex side (cleaner than ChatGPT web).
4. **Gemini CLI `/stats` parsing** — invoke the CLI in a subshell rather than poking files.
5. **Manual-entry fallback** for ChatGPT web and Gemini Advanced web. Acknowledge the gap in UI.

### Avoid

- Building a SaaS that ingests user OAuth tokens — local-only architecture.
- Scraping `claude.ai`, `chatgpt.com`, `gemini.google.com` directly — anti-bot will defeat you.
- Treating the Anthropic OAuth `/usage` endpoint as a stable contract.
- Conflating subscription quota with pay-as-you-go API spend.

### Consider

- Contributing a real PR to Claude Code that exposes `/usage` data in statusLine JSON — this is what the community wants and what would unblock everything. (Risky: Anthropic has declined the feature 6+ times. But maybe a cleanly scoped MR lands now.)
- An **MCP server** that abstracts "current quota per provider" so any client (Claude Code itself, Vibe Kanban, custom dashboards) can query it.

## References

- Claude OAuth `/usage` rate-limit issue: <https://github.com/anthropics/claude-code/issues/31637>
- Anthropic statusLine quota requests (closed): #22428, #28999, #27829, #27915, #27636, #20413
- Claude Code session file format: <https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b>
- Anthropic Usage & Cost API (API-only): <https://platform.claude.com/docs/en/build-with-claude/usage-cost-api>
- Codex `app-server` README: <https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md>
- Codex usage with ChatGPT plan: <https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan>
- Codex `/backend-api/wham/usage`: <https://www.knightli.com/en/2026/04/12/codex-usage-quota-check/>
- Gemini CLI quota & pricing: <https://geminicli.com/docs/resources/quota-and-pricing/>
- Gemini Apps subscription limits: <https://support.google.com/gemini/answer/16275805>
- ChatGPT Plus 2026 limits: <https://blog.laozhang.ai/en/posts/chatgpt-plus-usage-limits>
- Ian Paterson three-quota script: <https://ianlpaterson.com/blog/tracking-claude-codex-gemini-quotas-from-one-script/>
