# Research: Critical Assessment — Should You Build This?

**Date:** 2026-04-27
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

**My honest, skeptical take:** the *tracking* half of this idea is mostly already solved (for Claude Code) or impossible (for ChatGPT.com/Gemini Advanced web subscriptions, where providers refuse to expose data). The *productivity* half — auto-suggesting backlog work based on remaining quota — has no OSS equivalent and is the genuinely novel contribution, but it's also the part most likely to be solving a non-problem. **The economics are weaker than they look.** Maximum theoretical "wasted" quota on Claude Pro is roughly $14/month if you used 0 messages (clearly not the case if you bothered to subscribe). For someone holding 3–4 paid subscriptions, the realistic dollar value of optimizing leftover capacity is **on the order of $10–30/month**, against a build/maintain cost likely 10–100x that in time. Build it as a learning POC and an MCP server that AI agents can consult, **not** as a productivity-savings play.

## Steel-Man for Building It

### 1. The information gap is real and painful

Anthropic, OpenAI, and Google all explicitly refuse to expose subscription usage in tool-friendly formats. GH issue #22428 has 30+ upvotes; six separate Anthropic issues asking for the same thing have been closed. There is genuine, persistent, articulated demand for "show me my quota in my tools."

### 2. Multi-subscription power users do exist

The user (and roughly the audience reading r/ClaudeAI, r/ChatGPTPro, AI-developer Substacks) genuinely holds 2-4 paid subscriptions. The combined floor at retail prices is:
- Claude Max 5x: $100/mo
- ChatGPT Pro: $200/mo
- Google AI Pro: $20/mo
- = $320/mo baseline; up to $570/mo with Anthropic Max 20x or AI Ultra.

At those dollar levels even modest improvements in utilization are non-trivial.

### 3. Quota-aware AI scheduling is genuinely interesting

If "AI capacity" is treated as a reservoir that resets weekly, then "queue work to drain the reservoir before reset" is a real optimization problem. In enterprise AI/GPU scheduling (Run:ai, Azure quota tooling) this is treated as a serious problem. There's an intellectual case for personalizing it.

### 4. MCP-shaped solutions are a force multiplier

If the daemon exposes quota state as an MCP tool, **any** AI agent (Claude Code itself, Cursor, custom dispatchers, Vibe Kanban) can consult it during planning. "Before starting, check available capacity" becomes a primitive. That's a small artifact with broad reach.

### 5. The OSS niche is open

Despite a saturated API-observability space and a competent CLI-tracker space, **no OSS project unifies subscription-quota state across providers**. First-mover advantage on a small, focused tool is real.

### 6. Learning value

Reverse-engineering Anthropic OAuth, Codex JSON-RPC, and JSONL parsing is itself excellent agentic-coding-kanban POC material. This task validates the user's own workflow (research → tasks → implementation) on a domain they care about.

## Steel-Man Against Building It

### 1. The economics are much weaker than the framing suggests

Let's actually do the math instead of hand-waving.

**Claude Pro ($20/mo, ~45 msg / 5h, weekly cap):**
- ~45 msg × 6 windows/day × 7 days = ~1,890 theoretical max msgs/week before hitting the 5h cap.
- Weekly cap is unspecified but binds for "heavy users."
- If you "waste" 30% of your weekly quota — already a generous assumption for someone who chose to pay — that's $6/mo of dollar-equivalent value left on the table.
- Could you do anything actually useful with 30% of a Pro plan's residual messages? In small-task terms, probably yes. In dollar-savings terms, you're optimizing $6/mo.

**ChatGPT Plus ($20/mo, dynamic limits):**
- Same shape; limits "fluctuate based on demand."
- Realistic waste: $5-10/mo.

**Claude Max 5x ($100/mo):**
- Heavier users; weekly cap binds them more often.
- These users typically run **out** of quota, not have leftover. Less waste, more rationing.

**Google AI Pro ($20/mo):**
- Web limits "increase with subscription" but vague.
- Realistic waste: $3-8/mo.

**Combined realistic dollar-recoverable value: $15-40/mo.**

Compare to the **build/maintain cost**:
- Initial POC: 20-60 hours of work.
- Ongoing maintenance: undocumented endpoints break — call it 2-5 hours/month.
- At a developer's hourly opportunity cost ($50-200/hr), the project pays back in **never** for a single user.

The *economic* framing is wrong. This idea has to be justified on grounds other than "wasted money."

### 2. The "active suggester" might be solving a non-problem

The unstated assumption: a user with leftover Claude quota will look at a suggestion and act on it. Realistic alternative: they ignore it because the things they actually want to do don't fit "available now in 30% of a Pro plan."

Compare to existing "should I do something useful" prompts (Notion templates, RescueTime, Habitica). Adoption is uniformly low. Most knowledge-work backlogs are aspirational, not actionable. The user already chose what to do today; the residual is residual for a reason.

A more realistic workflow: "I have a backlog of small AI-augmentable tasks; show me which ones fit current capacity." That's a manual decision-support tool, not auto-dispatch. It's also much smaller in scope and value.

### 3. Power users already have heuristics

Most heavy AI subscribers already know roughly when their quota resets, watch the in-app counters, and have an intuitive sense of "I have a lot left, I can run that big refactor." A dashboard at best tightens this loop modestly. It rarely changes behavior.

### 4. Web subscriptions are technically intractable

ChatGPT.com web and Gemini Advanced web are unmeasurable from outside the browser. Any honest system has to admit "manual entry" or "install our extension and only count what happens in this Chrome profile." That's a fundamental UX limitation that probably defeats the unified-dashboard pitch.

### 5. Rate-limited foundational endpoint

The Anthropic OAuth `/usage` endpoint — the only path to true Claude.ai quota — is so aggressively rate-limited that GitHub issue #31637 reports tools being stuck in 429 lockouts for 30+ minutes after low-frequency polls. Polling it every 5 minutes is risky; every 1 minute (the cadence a user would want for a live dashboard) is impossible. The product experience is constrained by Anthropic's hostility to dashboard tooling.

### 6. The provider can fix this any day

If Anthropic decides next month to ship `/usage` data in the statusLine JSON (as the community has begged), most of the Claude side of this product becomes a 50-line script. The same risk applies to OpenAI and Google. This is a build-on-quicksand domain.

### 7. Backlog-driven scheduling needs a backlog

Most users don't keep a structured personal backlog with reasonable size estimates. Building a tool that **requires** users to maintain one is asking for behavior change before delivering value — a classic adoption antipattern. The successful alternative would be reading from existing systems (Linear, Notion, Things, Obsidian) — significantly more integration work.

### 8. Anthropic Routines may eat the productive-use angle directly

Claude Code Routines (Anthropic's own scheduled headless agents) already let users say "run X every weekday morning." If Anthropic adds quota-awareness to Routines (likely, since they manage the quota), the third-party tier is squeezed.

## Verdict

### What I'd actually build, if anything

**A small, deliberately scoped MCP server + CLI** named something like `aiquota`:

- Read-only.
- Local-first; no SaaS, no network calls except to providers' own endpoints.
- Pluggable provider backends; ships with claude-oauth, claude-jsonl, codex-app-server, codex-jsonl, gemini-cli-stats, gemini-jsonl, plus `manual` for opaque web subscriptions.
- Pydantic V2 models for normalized "quota state."
- Single CLI: `aiquota status` (one snapshot), `aiquota watch` (live updates), `aiquota fits "<task description with size>"` (which provider has capacity).
- MCP server mode: exposes `get_quota_state` and `find_capacity_for(estimated_tokens)` as tools that any AI agent can call mid-conversation.

That's it for v1. **No backlog. No suggester. No dispatcher.** Validate the foundation, see what people actually want to build on top, then layer.

The user's "auto-suggest project from backlog" idea is the speculative dessert — not the appetizer.

### What I'd build it as

- A learning POC for the agentic-coding-kanban planning workflow itself. The user gets to exercise their planning system on a project they actually want, even if the economic ROI is weak.
- An MCP-tool primitive that becomes useful **when** AI agents become more autonomous and need to know their own remaining capacity. Forward-leaning bet on the agent-centric future.
- A small, defensible OSS contribution in a niche that's currently empty.

### What I'd explicitly NOT pitch as

- A money-saving tool. The numbers don't support it.
- A productivity transformation. The "you have capacity, run X" UX is unlikely to survive contact with real user behavior.
- A startup. The TAM is too small and the foundations are too fragile.

## Validated Assumptions

| Assumption | Status | Evidence |
|---|---|---|
| Wasted quota is meaningful in dollar terms | Incorrect | Realistic recoverable value $15-40/mo across 3-4 subscriptions; far below maintenance cost |
| "No existing OSS solves this" | Partial | True for the **unified, web-subscription-aware, productivity-tied** version; false for the Claude-Code-CLI-only slice |
| Subscription quota can be measured reliably | Partial | Yes for CLIs (with caveats); no for web subscriptions; fragile for Claude.ai OAuth |
| Auto-suggesting backlog work is a real workflow | Incorrect (skeptical) | No precedent in OSS or commercial; analogous "should I do X" prompts have poor adoption |

## Risks Identified

### 1. Solving for an audience of one (Severity: High)

The user describes their own pain. Plausible, but the universe of people who (a) hold 3+ paid subscriptions, (b) maintain structured backlogs, (c) want AI auto-dispatch is small. Don't extrapolate user-of-one demand to broader market.

### 2. Foundation can be removed (Severity: High)

Provider can change the OAuth endpoint, ship native dashboards, or expose statusLine JSON, gutting the project's reason to exist.

### 3. Behavior change required (Severity: Medium)

Users would need to maintain a sized backlog for the suggester to work. Users typically don't.

### 4. Maintenance treadmill (Severity: Medium)

Three providers' undocumented endpoints, three CLI session-file formats subject to upstream change. Constant churn for a personal-use tool.

### 5. Sunk-cost framing (Severity: Low — psychological)

The user might invest disproportionate time because "I'm already paying for this." The cost is sunk; new effort to optimize it should be evaluated on its own marginal merits, which are weak.

## Open Questions

- [ ] What's the user's actual subscription mix and typical monthly utilization? (If they're at 95% utilization on Max already, this whole "wasted quota" framing collapses — they need *less* quota, not better tracking.)
- [ ] Does the user already maintain a structured backlog, or would the project require building one first?
- [ ] Is the goal more about (a) hobbyist OSS contribution / learning vehicle, (b) personal productivity, (c) commercial product? The right scope is very different in each case.
- [ ] Would the user accept a "manual entry for web subscriptions" UX, or does it have to be fully automated?

## Recommendations

### Recommended: Proceed with sharply constrained scope

Build `aiquota` as a 2-3 week solo POC with the explicit goal of "ship a small useful MCP server + CLI." Treat it as:

1. A learning vehicle for the agentic-coding-kanban planning workflow.
2. An MCP-tool primitive useful for future agent automation.
3. A genuine OSS contribution to an empty niche.

**Cut from POC scope:**
- The backlog/suggester layer entirely.
- Web-subscription scraping ambitions.
- Multi-user, sharing, SaaS, dashboards beyond CLI text.
- Anything Anthropic Routines / Claude Code Dispatch already handles.

**Keep in POC scope:**
- Local daemon / CLI.
- Claude OAuth `/usage` poller with rigorous rate-limit hygiene.
- Codex `app-server` JSON-RPC client.
- Gemini CLI `/stats` parser.
- Local JSONL readers for all three.
- Pydantic V2 normalized state.
- MCP server façade.
- A tiny "fits this task?" CLI command.

### Avoid

- Building it as a productivity app. The productivity claim is the weakest part of the pitch.
- Marketing it as money-saving. Math doesn't support it.
- Launching as SaaS. Local-only architecture preserves trust and avoids a maintenance burden.
- Building a kanban — Vibe Kanban has won that.

### Reconsider before proceeding

If the user's underlying motivation is "feel less guilty about paying for AI subscriptions I don't use enough," the cheapest fix is to **downgrade tiers** (Pro → no Pro), not build infrastructure to optimize residuals. The cleanest version of the "wasted money" problem is solved by spending less, not by building tools.

If the underlying motivation is "I want a side project that exercises the agentic-coding-kanban workflow on a domain I care about," then yes, this is a fine choice — but pitch it as that internally.

## References

- All sources cited in 01-oss-landscape.md and 02-provider-data-availability.md.
- Pricing math derived from: Claude Pro support docs, ChatGPT Plus 2026 limits guide, Google AI Pro/Ultra subscription page.
