# Research: Revised Viability — Build / Extend / Wrap / Abandon

**Date:** 2026-04-27
**Status:** Complete
**Researcher:** Sahaidachny Research Agent
**Supersedes:** [`04-critical-assessment.md`](./04-critical-assessment.md) for the broader product scope. The original `04` document remains valid only for the narrow "save money on quota" framing.

## Summary

Under the revised vision (parallel-session mission control + state visibility + multi-provider quota + backlog-aware capacity), the project moves from "weak" (the quota-only framing of `04`) to **"plausibly net-positive, with sharply different recommendations than the v1 framing".** The unique combination is: **(state-detection across all three major agents) + (Ghostty AppleScript focus) + (multi-provider quota aggregation) + (lightweight watcher architecture, not spawner)**. None of the 30+ orchestrators in the awesome list combines those four. However, the **throughput value prop is real but weaker than the user thinks**: at 6–7 parallel sessions, simple tab-naming discipline + a Notification Center summary already buys 60–70% of the value. The right call is **build new, scoped narrowly to the watcher model, with cmux on the radar as both a precedent and a "buy not build" alternative for the parallel-session-view sub-piece**. Do *not* extend Vibe Kanban (sunsetting, model mismatch). Do *not* market this as a productivity transformation — pitch it as a personal mission-control utility with optional MCP exposure.

## Steel-Man for Each Path

### Path 1: BUILD NEW (the lean watcher dashboard)

**What it is:** A small daemon + UI (TUI or native macOS app) that:
1. Listens for hooks from Claude Code (HTTP), Codex (JSON-RPC), Gemini CLI (curl wrapper), normalizes them into a unified `SessionEvent` stream.
2. Maintains an in-memory "session registry" keyed by `(agent, cwd, session_id)`.
3. Polls Ghostty via AppleScript every 2–5s to map cwd <-> Ghostty tab.
4. Aggregates quota state across providers (Claude OAuth `/usage`, Codex token-usage notifications, Gemini CLI stats, plus optional manual entry).
5. Renders a "wall of sessions" view; clicking a session calls AppleScript to focus that Ghostty tab.
6. Optionally exposes its own MCP server so any agent can ask "what's my remaining quota?" or "how many sessions are blocked?".

**Unique combination only the user is building:**
- **Watcher, not spawner** (only Codeburn / Codeman do this on the dashboard side, and neither integrates with Ghostty). **As of 2026-06-15 this is no longer just a workflow-fit preference — it is an economic requirement.** `claude -p` / Agent SDK usage now draws from a separate, capped credit pool ($20 Pro / $100 Max5x / $200 Max20x) that hard-stops with no fallback, distinct from interactive limits. A spawner burns the wrong pool; a watcher of native interactive sessions keeps the quota model coherent. See [`10-claude-p-quota-change.md`](./10-claude-p-quota-change.md).
- **Cross-provider quota aggregation** (only ccusage / Codeburn / Claude Code Usage Monitor cover sub-pieces; nobody unifies subscription quota across Anthropic + OpenAI + Google).
- **Ghostty AppleScript focus** (no orchestrator project does this; cmux uses libghostty as a renderer, not Ghostty.app via AppleScript).
- **Lean enough to run alongside, not replace, the user's existing setup.**

**Pros:**
- Architecturally clean. Each piece (Claude hooks, Codex JSON-RPC, Gemini hooks, AppleScript, quota aggregator) is small and independently testable.
- No upstream dependency on a maintainer-abandoned project.
- The user gets to validate their own agentic-coding-kanban planning workflow on a project they care about — already a stated motivation.
- Very plausibly an MCP primitive other agents will use later.

**Cons:**
- Genuinely a new product. Estimated 4–8 weeks of focused build for v1, plus ongoing maintenance across three agent CLIs and Ghostty's evolving capabilities.
- The maintenance treadmill is real: provider hook schemas change, Codex's app-server is still evolving, Ghostty `Ghostty.sdef` could shift, ccusage-style quota endpoints are undocumented.
- Marketing/positioning risk: "yet another agent orchestrator" in a field of 30+. Differentiation must be communicated clearly.

**Honest cost estimate:** 60–120 hours initial + 2–6 hours/month maintenance, depending on how far the user goes (TUI vs. native macOS, optional MCP server, optional backlog integration).

### Path 2: EXTEND AN EXISTING PROJECT

#### Option 2a: Extend Vibe Kanban
- **Status:** Project is sunsetting (BloopAI announcement). Continues as community-maintained OSS.
- **Architectural mismatch:** Vibe Kanban is a spawner — it owns the workspace, branch, terminal, dev server. The user's vision is a watcher of *existing* sessions in Ghostty. Bolting watcher behavior onto a spawner means significant invasive changes.
- **Economic disqualifier (new, 2026-06-15):** as a spawner it drives Claude headlessly, which now burns the separate Agent SDK credit pool, not the user's interactive subscription quota. For a quota-aware tool this is backwards — it spends an invisible second pool that hard-stops mid-cycle. This, not the sunsetting, is the headline reason it doesn't fit. See [`10-claude-p-quota-change.md`](./10-claude-p-quota-change.md).
- **Adoption risk:** contributing to a maintainer-abandoned project means upstream may never merge. User ends up forking. Equivalent cost to building new, with extra debt from understanding someone else's Rust + TS codebase.
- **Verdict:** Not recommended.

#### Option 2b: Extend cmux
- **Status:** Active, GPL-3.0, native macOS, libghostty-based.
- **Architectural fit:** cmux already has socket API + sidebar metadata + notification rings + Claude Code teammate integration. Adding "quota awareness" is plausibly a feature contribution rather than a fork.
- **Risks:** GPL-3.0 contagion (downstream MCP server / CLI must also be GPL). The user must accept that their dashboard becomes a cmux extension, which means switching from Ghostty.app to cmux.app. The user's stated requirement is "do NOT replace Ghostty" — cmux uses libghostty as a renderer (config, themes, fonts compatible) but is not Ghostty.app. Whether this counts as "replacement" is a user decision.
- **Trajectory uncertainty:** cmux is small enough that there's no commitment to merge upstream contributions.
- **Verdict:** Worth a serious conversation with the user. If they're OK with cmux.app, this is the lowest-effort path to 60–70% of the parallel-session-view + state-visibility halves of the vision. Add a quota layer and ship it.

#### Option 2c: Extend Codeburn / Codeman
- **Status:** Codeburn (token observability TUI) and Codeman (web UI with token tracking + tmux) are the closest projects on the quota axis.
- **Architectural fit:** good on the quota half; nothing on the parallel-Ghostty-session-view half.
- **Realistic outcome:** the user's project ends up rebuilding the dashboard half on top of Codeburn-style data sources. Roughly equivalent to "wrap existing tools as data sources" (Path 3).

### Path 3: WRAP EXISTING TOOLS AS DATA SOURCES

**What it is:** The user builds *only* the dashboard layer + the AppleScript Ghostty integration. All quota/state data is sourced from existing libraries:

- **Quota:** ccusage (Claude), Codeburn / cc-usage-style for Codex, gemini-cli stats command.
- **State:** subscribe to Claude Code HTTP hooks, Codex JSON-RPC, Gemini CLI hook wrappers — but treat each as an independent data source rather than building a unified ingestion daemon.

**Pros:**
- Smallest possible build surface. Maybe 30–50 hours for v1.
- Most resilient to provider changes — when ccusage updates, the user inherits the fix for free.

**Cons:**
- Three different schemas to reconcile in the UI layer. State drift across data sources.
- Each upstream library is one bus-factor away from breaking. ccusage-style projects are actively maintained today but small.
- The user still has to write the AppleScript Ghostty layer and the cross-provider state aggregator — those are the actual hard parts. So the savings vs. Path 1 are modest.

**Verdict:** A defensible v0.1 stepping-stone, but converges with Path 1 at v0.5.

### Path 4: ABANDON

Steel-man this seriously, because the user explicitly asked.

**Is the throughput value prop overstated?**

Probably partially overstated. Honest accounting:

- **The "I forgot about a session" problem** is real but tractable with a 5-minute fix: name your Ghostty tabs after the project, set a fish/zsh `precmd` that updates the title with a state hint (`my-project [waiting]`), and check tabs every 15 minutes. This is paper-kanban-equivalent and costs nothing to build.
- **The "context-switch state recovery" problem** is largely solved by Claude Code's session resume + transcript files. Switching tabs and reading the last 30 lines of context recovers the project state in 5 seconds. A dashboard saves *seconds* per switch, not minutes.
- **The "I have spare quota; what should I start" problem** assumes the user has a structured backlog with sized estimates. As `04-critical-assessment.md` notes, most users don't. The dashboard can suggest "start project X" only if project X is already enumerated and characterized — which is itself work the user has to do manually.
- **The "managing 8 parallel projects instead of 5" prediction** is plausible but unverified. Real bottleneck for parallel agentic coding is usually not "where am I" but "I cannot review 8 PRs in parallel." Cognitive review bandwidth, not session-tracking bandwidth, is the limiting reagent past 4-5 parallel agents for most humans.

**Where the value prop is real:**

- **Notification convergence:** instead of N separate Ghostty windows blinking with N different agent notifications, one dashboard ring. This is genuinely useful and not solvable by tab naming alone.
- **Cross-provider quota visibility:** even at $15-40/mo recoverable savings (the original `04` math), the *peace of mind* of seeing "Claude 60% used, Codex 40%, Gemini 80%" at a glance is non-trivial. This is a real-time information good, not a savings good.
- **MCP primitive future:** if the daemon exposes quota + session state as MCP tools, future agents can self-throttle. Forward-leaning bet.

**Honest abandon argument:**

If the user's actual workflow is 3–4 parallel sessions (not 6–7), and they're OK with paper-kanban tab discipline + occasional manual quota checks, **the build cost is greater than the realistic throughput gain**. This is a legitimate option.

**Counter:** the user is the kind of person who is going to build *something* in this space because it scratches a personal itch. Better to scope it tightly than to abandon and build something less considered.

## Throughput Value Recomputed

Original framing recompute (replacing the $/mo savings story with throughput):

- **Baseline (no dashboard):** user manages ~3-5 parallel agentic sessions before dropping balls or burning quota inefficiently.
- **With dashboard (optimistic):** maybe 6-8 parallel sessions sustainable, *if* state visibility and notification convergence are good.
- **Marginal capacity gain:** 2-3 additional projects per cycle.
- **Value of one additional shipped project:** highly variable. For a senior dev's side projects, plausibly $200-500 of equivalent contractor time. For commercial projects, plausibly $500-2000.
- **Annual upside (optimistic):** 2-3 extra projects/cycle × 4 cycles/month × 12 months × $300/project = $43k to $86k of equivalent throughput value.
- **Realistic upside:** 50% of optimistic = **$20k-40k/year**.
- **Build cost:** 60-120 hours × $100/hr (opportunity cost, not market) = $6k-$12k one-time.

**Verdict:** the throughput math closes if the user actually uses 6+ parallel sessions and ships marginal projects to completion. If parallel-session usage is overstated (e.g., user runs 3 sessions and the rest are aspirational), the math collapses.

**Critical sensitivity:** does the user genuinely run 6-7 parallel sessions today? This is the single most important data point for the build-vs-abandon decision. Anything below 5 makes Path 1 hard to justify; anything at 6+ makes it easy.

## Recommendation

### Recommended path: BUILD NEW (Path 1) with sharp scope

Build a small **watcher** dashboard with the following v1 cut:

**In scope for v1 (4–8 weeks):**
- Local daemon (Python + Pydantic V2 per the user's code style preferences) that:
  - HTTP hook receiver for Claude Code on `127.0.0.1:7891`.
  - JSON-RPC client to Codex `app-server` (Unix socket).
  - HTTP wrapper for Gemini CLI hooks (small bash scripts that POST to the daemon).
  - AppleScript poller for Ghostty tab/cwd state every 2-5s.
  - Normalized `SessionEvent` + `SessionState` Pydantic models.
- Quota aggregation layer:
  - Claude usage poller covering **both Anthropic pools** (2026-06-15 split): the interactive 5h-rolling-window + weekly cap, *and* the separate Agent SDK credit pool — clearly labeled so the user can see headless tools (e.g. Vibe Kanban) drain the second pool. Rigorous rate-limit hygiene (per `04-critical-assessment.md` warnings). See `10-claude-p-quota-change.md`.
  - Codex `thread/tokenUsage/updated` ingestion.
  - Gemini CLI `/stats` parser.
  - Optional `manual` provider for opaque web subscriptions.
  - **Hard constraint:** the daemon itself performs **zero** `claude -p` / Agent SDK calls — all session state is derived from observation signals (hooks, JSONL tail, statusline, OTEL). It must never spend the pool it reports on.
- TUI (Textual or Rich) — small, fast, runs as a Ghostty tab itself. Native macOS app deferred to v2.
- "Click a session, jump to its Ghostty tab" via AppleScript `activate window` + `select tab`.
- Notification convergence via macOS NSUserNotification.

**Cut from v1:**
- Backlog management UI. Manual JSON file for "projects I want to do" is enough.
- Suggester / auto-dispatcher. Show capacity; let the user decide.
- Web subscription scraping.
- Linux / Windows support.
- Multi-user / SaaS / cloud sync.
- Native macOS app (do TUI first; native is v2 if there's appetite).
- MCP server façade — defer until the v1 daemon is stable.

**Acceptance criteria for v1:**
1. Daemon receives Claude Code `Stop` and `Notification[permission_prompt]` hooks within 100ms in a real session.
2. Daemon subscribes to Codex `app-server` and reflects `thread/status/changed` events in the TUI within 200ms.
3. Daemon detects a Gemini `BeforeAgent` event via wrapper script.
4. AppleScript `select tab` + `activate window` reliably focuses the right Ghostty tab in <500ms when clicked in TUI.
5. Quota panel shows current Claude OAuth `/usage`, Codex token usage, and Gemini stats simultaneously.
6. Crash recovery: daemon dies, restarts, reconstructs session state from JSONL tails within 5s.

### Pitch internally as

- **Personal infrastructure**, not productivity transformation. Build to use, not to launch.
- **Forward-leaning MCP primitive.** The MCP exposure (deferred to v2) is the real long-term bet — a daemon that any future agent can consult for "where are we, what's free."
- **Validation of the agentic-coding-kanban workflow.** Already a stated motivation in `04`.

### Pitch externally (if/when shared) as

- **"Ghostty mission control + multi-provider quota dashboard for solo developers running parallel agents."**
- Not as a productivity transformation, not as a money-saver, not as a startup. As a focused OSS utility that fills a niche the 30 named orchestrators don't.

### Watch list (kill criteria)

If any of the following happen during the build, stop and reassess:

- **cmux ships quota tracking.** Then "extend cmux" beats "build new" almost certainly.
- **Anthropic adds quota state to statusLine JSON or hook payloads.** Then the Claude side becomes 50 LOC and the dashboard's added value shrinks.
- **Vibe Kanban community fork picks up momentum and goes watcher-shaped.** Then the OSS niche the dashboard occupies narrows.
- **The user's actual parallel-session count after 2 weeks of dashboard use is < 4.** Then the throughput math fails and the project is just hobby infra.

## Validated Assumptions (Revised Scope)

| Assumption | Status | Evidence |
|---|---|---|
| Throughput is the real value prop, not savings | Confirmed | Math in this doc closes for throughput, fails for savings |
| The combination of pillars is uncovered by existing tools | Confirmed | Comparison matrix in `07-orchestrator-landscape.md` |
| Build-new is the right path | Partial — depends on cmux | Build-new beats extend-Vibe-Kanban; build-new ties extend-cmux depending on user's "no replace Ghostty" interpretation |
| State detection is technically feasible | Confirmed | `06-agent-state-detection.md` rates all three agents from medium to high feasibility |
| Ghostty per-tab focus is feasible from external app | Confirmed (macOS) | AppleScript dictionary in `Ghostty.sdef` |
| User runs 6-7 parallel sessions | Unverified | Self-reported; **single most important assumption to validate before building** |

## Risks Identified (Revised)

### 1. User's actual parallel-session count is overstated (Severity: HIGH — kill criterion)
The throughput value collapses below 5 parallel sessions. Validate this **before** committing 60+ hours.

### 2. cmux trajectory eats the niche (Severity: Medium — watch list)
cmux is the closest existing tool and active. If it adds quota in the next 6 months, "build new" becomes hard to justify.

### 3. Maintenance treadmill across 3 agent CLIs + Ghostty (Severity: Medium)
All four upstream surfaces will change. Budget 2-6 hours/month indefinitely.

### 4. AppleScript-only macOS limitation (Severity: Low for v1)
Acceptable scoping decision. Document it.

### 5. Three different hook ecosystems means three different latency budgets (Severity: Medium)
Claude Code HTTP hook timeout, Codex JSON-RPC notification cadence, Gemini synchronous-blocking hook. Daemon must be fast on all three.

### 6. The "click to jump to tab" UX is good, but not magical (Severity: Low)
Cmd-Tab + Cmd-{1..9} for Ghostty tabs already takes a fraction of a second. Saving that is real but small. Pitch on state visibility + quota, not on focus speed.

## Open Questions

- [ ] **Critical:** what's the user's *actual* parallel-session count over the last 7 days? (Personal-data check; user should answer before committing.)
- [ ] Does the user accept cmux as "Ghostty enough" or does it count as replacement?
- [ ] Is the user willing to maintain a structured backlog (JSON file) for the suggester to be useful, or should the suggester be cut entirely?
- [ ] What's the user's TUI vs. native-app preference for the dashboard UI?
- [ ] Will the dashboard be solo-use forever, or eventually shared (which would change architecture)?

## Recommendations

1. **Before building anything: spend one day measuring your actual usage.** Count parallel Ghostty tabs running agents over 5 working days. If < 5, abandon or radically scope down. If ≥ 6, build.
2. **Talk to one cmux user** (or trial cmux yourself for a week) before committing to "build new". cmux may be 70% of what you want for ~0% of the build cost, modulo the "is libghostty.app close enough to Ghostty.app" question.
3. **If building, start with the daemon, not the UI.** A daemon that prints to stdout is enough to validate hooks + Codex JSON-RPC + AppleScript work. Add UI only after the data layer is reliable.
4. **Ship the MCP server façade in v2, not v1.** It's the most interesting future-leaning capability, but only matters if the v1 daemon is stable.
5. **Don't market this externally until you've used it for 30 days.** Internal validation is the highest-value input. The OSS niche is empty enough that being late to publish costs little.
6. **If you abandon, that's a legitimate decision.** Adopt cmux + ccusage + tab-naming discipline; the marginal value of building over that combination is genuinely uncertain.

## References

- `06-agent-state-detection.md` — feasibility evidence for the watcher daemon.
- `05-ghostty-integration.md` — AppleScript focus mechanics.
- `07-orchestrator-landscape.md` — competitive landscape, build-vs-extend basis.
- `04-critical-assessment.md` (superseded for product scope; still valid for the narrow quota-only economics).
- `02-provider-data-availability.md` — quota data source feasibility.
