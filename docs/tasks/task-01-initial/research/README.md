# Research

Technical research and external-landscape analysis for **task-01-initial: Agentic Coding Mission Control** (revised scope as of 2026-04-27).

## Two Research Passes

The task description was revised after the first research pass. The original framing was "save money on unused subscription quota"; the revised framing is "mission control for parallel agentic-coding sessions + multi-provider quota + backlog-aware capacity planning". Reports are split accordingly.

### Pass 1 — Quota-only scope (older framing, partially superseded)

| File | Purpose | Status |
|---|---|---|
| [01-oss-landscape.md](./01-oss-landscape.md) | Survey of OSS quota trackers (ccusage, Claude Code Usage Monitor, Codeburn, etc.). | Still valid — quota-tracker landscape unchanged. |
| [02-provider-data-availability.md](./02-provider-data-availability.md) | What Anthropic, OpenAI, Google expose for subscription quota — APIs, undocumented endpoints, local files, scraping. | Still valid — provider data availability unchanged. |
| [03-gap-analysis.md](./03-gap-analysis.md) | Coverage matrix: quota-tracker side. | **Partially superseded.** The matrix only covers the quota half of the broader vision; consult `07-orchestrator-landscape.md` for the orchestrator/state half. |
| [04-critical-assessment.md](./04-critical-assessment.md) | Skeptical evaluation under the **narrow quota-only** scope. Concluded "build small MCP server, weak savings story." | **Superseded for product scope** by `08-revised-viability.md`. The economics math (recoverable savings $15-40/mo) is still correct as a sub-piece argument; the overall recommendation is replaced. |

### Pass 2 — Mission-control scope (current framing)

| File | Purpose | Status |
|---|---|---|
| [05-ghostty-integration.md](./05-ghostty-integration.md) | Ghostty IPC / scripting / AppleScript / CLI feasibility for "jump to tab" UX. **Verdict:** AppleScript on macOS works; no cross-platform IPC; cmux is the closest precedent. | Current. |
| [06-agent-state-detection.md](./06-agent-state-detection.md) | Per-session state detection feasibility for Claude Code, Codex CLI, Gemini CLI. Includes signal-quality matrix. **Verdict:** Claude Code HIGH (HTTP hooks), Codex HIGH (JSON-RPC), Gemini MEDIUM (no permission-prompt hook). | Current. |
| [07-orchestrator-landscape.md](./07-orchestrator-landscape.md) | Mission-control / parallel-session orchestrator landscape. Comparison matrix across 30+ projects. **Verdict:** no project covers the user's four pillars; cmux is closest on terminal+state, Codeburn on quota; Vibe Kanban is sunsetting. | Current. |
| [08-revised-viability.md](./08-revised-viability.md) | Build / extend / wrap / abandon recommendation under the mission-control scope. Throughput value math. **Verdict:** build new with sharply scoped v1; validate user's actual parallel-session count first. | Current — supersedes `04`. |

### Pass 3 — Current OSS Reassessment (build-vs-adopt refresh)

| File | Purpose | Status |
|---|---|---|
| [09-current-oss-coverage.md](./09-current-oss-coverage.md) | Fresh OSS reassessment focused on the user's core question: does a single open-source tool now cover the full need, or does the product still need to exist? **Verdict:** no single tool covers all pillars; strongest path is either a multi-tool stack or a thin Ghostty-native integration layer. | Current. |

### Pass 4 — `claude -p` quota split (2026-06-15)

| File | Purpose | Status |
|---|---|---|
| [10-claude-p-quota-change.md](./10-claude-p-quota-change.md) | The 2026-06-15 change splitting `claude -p` / Agent SDK usage into a separate capped credit pool, and why it makes "watcher, not spawner" an economic requirement (not just a workflow preference). Re-scores spawner tools (Vibe Kanban et al.) and adds a second Anthropic quota pool to track. **Verdict:** hardens the build-a-watcher recommendation; spawners are now economically wrong for the target user. | Current. |

### Pass 5 — saha linkage + positioning (2026-06-15)

| File | Purpose | Status |
|---|---|---|
| [11-saha-relationship.md](./11-saha-relationship.md) | Distinction + linkage between this kanban and the user's **saha** (sahaidachny) project, verified from saha's source + v0.9.0 release. **Key finding:** saha's autonomous loop has **two launch paths** — `saha run` (terminal → `claude --print` subprocess → API-billed Agent SDK pool) and **`/saha:execute`** (v0.9.0, runs the loop *inside* an interactive Claude Code session via the Task tool → subscription-billed). So Flow A is **pool-flexible**, and a `/saha:execute` run is a native interactive session the watcher already observes (no saha-specific wiring). **Verdict:** kanban = saha's cockpit; integrate via Claude Code hooks (for `/saha:execute`) + saha files/hooks/token telemetry (for `saha run`); launch suggest-only and **route by pool**. | Current. |
| [12-two-flow-scheduling-model.md](./12-two-flow-scheduling-model.md) | The product thesis: the kanban is a **two-flow (autonomous/saha vs. interactive), two-pool (Agent SDK credit vs. interactive) capacity allocator**, not just a board. Formalizes the user's "optimize my schedule" goal as a two-resource allocation problem no orchestrator or tracker solves. **Verdict:** make flow-type + which-pool-it-spends first-class on every card; keep the allocator a suggest-only heuristic in v1. | Current. |
| [13-board-view-and-feature-parity.md](./13-board-view-and-feature-parity.md) | UX synthesis: **cmux tabs → board-with-drill-down** (focus the real Ghostty tab via AppleScript; optional read-only peek), plus a **Vibe Kanban feature-parity checklist** filtered through the watcher constraint (Adopt board+lifecycle+diff-review; Drop worktree/hosted-terminal/dev-server spawner machinery). **Verdict:** Vibe Kanban's board + cmux's card metadata, on a watcher core, with the capacity brain as the differentiator. | Current. |

### Pass 6 — UI mockup critique (2026-06-15)

| File | Purpose | Status |
|---|---|---|
| [14-ui-mockup-critique.md](./14-ui-mockup-critique.md) | Critique of the user's hand-drawn UI mockup against the `12`/`13` thesis. **Key finding:** the mockup's columns (Todo·Research·User Stories·Specs·Impl Plan·Agent Loop·Done) are saha's `/saha:*` *planning* lifecycle — a **single-task, Flow-A-only pipeline visualizer**, which drops Problem 1 (parallel *interactive* sessions / "who needs me") and risks the watcher constraint via a resident typable terminal. **Verdict:** keep the user's three good instincts (board-first, drill-down, quota visible), but **promote the quota panel into a two-pool capacity brain**, make the top board **state-columns + flow swimlanes** with a Waiting/Blocked attention count, and **demote the saha pipeline to the per-card drill-in** (Altitude 1). Reconciliation sketch + constraint check inside. Board-topology decision flagged for `/saha:decide`. | Current. |

## TL;DR (Current)

**Quota half (from passes 1+2):** well-covered for Claude Code; partial for Codex and Gemini CLI; intractable for web subscriptions. Realistic recoverable dollar savings $15-40/mo across 3-4 subscriptions — too small to justify on its own.

**Mission-control half (pass 2):**
- **Ghostty integration is feasible on macOS** via AppleScript (`Ghostty.sdef` exposes window->tab->terminal hierarchy with `focus`, `select tab`, `activate window`, `working directory`).
- **State detection is feasible for all three agents.** Claude Code HTTP hooks (28 events) and Codex JSON-RPC `app-server` are push-based and rich. Gemini CLI hooks work via curl wrapper but lack a direct "permission prompt opened" event.
- **No existing tool combines parallel-session view + state visibility + multi-provider quota + Ghostty integration.** Closest are cmux (terminal + state, no quota) and Codeburn (quota, no orchestration). Vibe Kanban is sunsetting.

**Verdict:** build new under a watcher (not spawner) architecture, scoped to a daemon + TUI in v1, with MCP server and native UI deferred to v2. **Critical pre-build check:** validate the user's actual parallel-session count (need ≥ 5 sustained for the throughput math to close).

**`claude -p` quota split (pass 4, 2026-06-15):** Anthropic moved `claude -p` / Agent SDK usage to a separate capped credit pool ($20 Pro / $100 Max5x / $200 Max20x), hard-stopping with no fallback, distinct from interactive limits. This makes **watcher-not-spawner an economic requirement**: the tool must drive/observe the *native interactive* `claude` in a real Ghostty PTY and never spend the headless pool itself. Spawner tools (Vibe Kanban et al.) now burn the wrong pool for subscription users. The quota pillar must track **both** Anthropic pools. See `10-claude-p-quota-change.md`.

**saha linkage + positioning (pass 5, 2026-06-15):** The kanban is **saha's cockpit**, not a competitor. saha = single-task autonomous *depth* engine; kanban = many-task *breadth* watcher + capacity allocator. **Verified from source + v0.9.0:** saha's loop has **two launch paths** — `saha run` (terminal subprocess → `claude --print` → API-billed Agent SDK pool) and **`/saha:execute`** (runs the loop *inside* an interactive Claude Code session via the Task tool → subscription-billed). So **Flow A is pool-flexible**: the same task can spend either pool depending on launch command, and a `/saha:execute` run is a native interactive session the watcher already observes (via Claude Code hooks/JSONL — no saha-specific wiring). saha also exposes file state + push hooks + **per-phase/per-runner token telemetry** to ingest. The product thesis sharpens to a **two-flow (autonomous vs. interactive), two-pool capacity allocator** whose core action is **routing the launch command to the pool with headroom** — Vibe Kanban's board + cmux's card metadata on a watcher core, with multi-pool quota as the differentiator no orchestrator or tracker has. Launch **suggest-only**; the board labels which pool each launch spends. See `11`, `12`, `13`.

**Fresh OSS reassessment (pass 3):**
- `cmux` is the strongest mission-control candidate, but only if replacing Ghostty.app is acceptable.
- `Agent Sessions` is the strongest session-browser/HUD candidate, but its live cockpit is iTerm2-based.
- `CodexBar` is the strongest current quota tracker for a direct Claude/Codex/Gemini workflow; `OpenCode Bar` is more OpenCode-centric.
- **No single OSS tool covers all required pillars.** If the product exists, it should exist as a thin Ghostty-native integration layer rather than a full new terminal/orchestrator.

See `08-revised-viability.md` for the full recommendation, kill criteria, and watch list.

## Reading Order

If reading fresh, suggested order:

1. `task-description.md` (one level up) — the revised problem statement.
2. `08-revised-viability.md` — the recommendation, with cross-references.
3. `07-orchestrator-landscape.md` — what already exists.
4. `06-agent-state-detection.md` — feasibility of the dashboard's hardest job.
5. `05-ghostty-integration.md` — feasibility of the "jump to tab" UX.
6. `02-provider-data-availability.md` and `01-oss-landscape.md` — quota-source background.
7. `03-gap-analysis.md` and `04-critical-assessment.md` — for historical context only.
8. `09-current-oss-coverage.md` — latest answer to "does this still need to exist?"
9. `10-claude-p-quota-change.md` — the 2026-06-15 quota split and why it locks in the watcher architecture.
