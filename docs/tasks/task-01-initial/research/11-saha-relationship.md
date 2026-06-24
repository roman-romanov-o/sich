# Research: Sahaidachny ("saha") Relationship — Distinction, Linkage, and the Spawner/Watcher Reconciliation

**Date:** 2026-06-15
**Status:** Complete
**Sources:** Local saha source at `/Users/romanromanov/MyProjects/sahaidachny/` (authoritative — read line-by-line), locally-installed saha plugin (`.claude/`, `.codex/`, `.gemini/` in this repo), [saha GitHub](https://github.com/roman-romanov-o/sahaidachny), plus external pass (cmux, Vibe Kanban) for contrast.

## Why this report exists

The user asked to **draw a distinction between `agentic-coding-kanban` and `saha`, and to link them.** saha is the user's *other* project: a structured-planning + autonomous-execution engine for a single task. This repo (`agentic-coding-kanban`) is mission-control + quota-aware capacity planning across *many* parallel sessions (see `task-description.md`, [[project_vision]], and the watcher-not-spawner constraint in `10-claude-p-quota-change.md`).

The headline finding: **the two projects are not competitors and not the same thing — they are complementary halves of one workflow, and they deliberately consume *different quota pools*.** That last fact is verified from saha's source and is the load-bearing insight for both the distinction and the integration design.

---

## 1. What saha actually is (verified from source)

saha = a **runner-agnostic CLI + multi-CLI plugin** that does two things:

### 1a. Interactive planning (in Claude Code, via `/saha:*`)
A lifecycle of slash commands produces a hierarchy of plain-Markdown artifacts under `docs/tasks/task-XX-name/`:

```
/saha:init → /saha:task → /saha:research → /saha:stories → /saha:decide
          → /saha:contracts → /saha:test-specs → /saha:plan → /saha:verify → /saha:status
```

Artifacts (confirmed from the installed `task-structure` skill): `task-description.md`, `user-stories/US-*.md` (acceptance criteria as `[ ]/[x]/[~]` checkboxes), `design-decisions/DD-*.md`, `code-changes/*.md` (interface specs — note the **folder is `code-changes/`, not `contracts/`**, even though the command is `/saha:contracts`), `test-specs/{unit,integration,e2e}/`, `implementation-plan/phase-*.md`, `research/*.md`, and a `README.md` task dashboard with a planning-progress table. Two modes: **Full** (existing codebases, all artifacts) and **Minimal** (greenfield: task + stories + DoD).

### 1b. Autonomous execution (in the terminal, via `saha run`)
`saha run <task-id>` starts an **agentic loop** (`saha/orchestrator/loop.py`, class `AgenticLoop`). Per iteration:

1. **Implementation** (`execution-implementer`, model: opus) — writes code per the plan, consumes `fix_info` from prior failures.
2. **Test Critique** (`execution-test-critique`) — detects hollow/missing tests *before* running them; completeness-weighted A–F score; C/D/F blocks QA.
3. **QA** (`execution-qa`, or `-playwright` variant) — verifies acceptance criteria, runs pytest; emits `dod_achieved` + `fix_info`.
4. **Code Quality** (`execution-code-quality`) — runs Ruff / ty / complexipy on changed files only, filters false positives.
5. **Manager** (`execution-manager`) — edits the task artifacts on disk: checks off `[x]` ACs, flips story Status, marks plan phases done.
6. **DoD gate** (`execution-dod`, model: haiku) — reads all stories/phases and returns `task_complete: true/false`. **No auto-completion fallback** — the loop only ends when DoD explicitly passes (or `max_iterations`, default 10, is hit). Any failed phase loops back to step 1 with `fix_info`.

Runner-agnostic: `RunnerRegistry` lets each agent use a different backend (`SAHA_AGENTS__DEFAULT_RUNNER=codex|gemini|claude`); `saha resume` continues a saved `ExecutionState`. **v0.9.0 adds an in-session equivalent — `/saha:execute` / `/saha:resume` — that runs this same loop inside an interactive Claude Code session (subscription-billed) instead of shelling out; see §3.** (Note: this repo's currently-synced `.claude/commands/` predates v0.9.0 and lacks `saha:execute`/`saha:resume` — a `saha sync` would add them.)

---

## 2. The distinction (depth vs. breadth; spawner vs. watcher)

| Axis | **saha** | **agentic-coding-kanban** |
|---|---|---|
| Unit of work | **One task**, planned deeply | **Many tasks/sessions**, in parallel |
| Direction | **Vertical** — drive one task to a verified DoD | **Horizontal** — situational awareness + capacity across all of them |
| Lifecycle role | The *engine* that does the work | The *cockpit* that watches the work and schedules attention |
| Process model | **Spawner OR in-session** — `saha run` launches headless subprocesses (`claude --print`/`codex`/`gemini`); **`/saha:execute`** (v0.9.0+) runs the loop *inside* an interactive Claude Code session via the Task tool | **Watcher** — observes existing sessions; never spawns anything itself (constraint from `10-claude-p-quota-change.md`) |
| Quota pool consumed | **Either pool, by launch method**: `saha run` → Agent SDK credit (API-billed); `/saha:execute` → interactive subscription; or Codex/Gemini pools | Consumes *nothing* itself; it *measures* all pools |
| Output | Code changes + updated artifacts on disk | A board view + "what to start next" recommendations |
| Human touch-point | At the ends: plan it, then review results | Continuous: the glance that says "who needs me" |

One sentence: **saha makes one task autonomous; the kanban makes your whole portfolio of tasks legible and schedulable.**

---

## 3. The verified crux (saha v0.9.0): TWO execution entry points → different pools

> **Correction note (2026-06-15):** an earlier draft of this report claimed saha is *only* a `claude --print` spawner that lives on "the other pool." That described just one of saha's two entry points. saha **v0.9.0 ("subscription-billed execution")** added an in-session path. Both are documented below; this is the single most important fact for the kanban's quota model.

The **same loop** (`orchestrator/loop.py`: implementation → test_critique → qa → code_quality → manager → dod_check) has two launch paths:

| Entry point | Where the loop runs | Billing | Source |
|---|---|---|---|
| **`saha run` / `saha resume`** (terminal CLI) | shells out to a **`claude --print`** subprocess (or `codex` / `gemini`) | **API-billed** → the capped **Agent SDK credit pool** (hard-stop, no fallback) | `runners/claude.py` builds `["claude","--print",…]`; `commands/execution.py:357` self-documents "billed against API credits, not your subscription" |
| **`/saha:execute` / `/saha:resume`** (slash command **inside Claude Code**, v0.9.0+) | the **active interactive Claude Code session** runs the loop, dispatching each phase to native subagents via the **`Agent`/`Task` tool** — **no subprocess** | **subscription-billed** → the **interactive pool** | `.claude/commands/saha:execute.md`: "All subagent calls go through the active session… usage is billed against the current Claude subscription — no `claude -p`, no Agent SDK" |

`/saha:execute` *is* the orchestrator re-expressed as a recipe Claude follows in-session (`allowed-tools: …, Task`); it persists state to `.sahaidachny/<task>-execution-state.yaml` between phases and is resumable via `/saha:resume`.

**Consequences (these supersede the earlier "opposite pools" framing):**

1. **Flow A (autonomous saha) is pool-flexible.** The *same task* can be billed to the **Agent SDK credit pool** (`saha run`) **or** the **interactive pool** (`/saha:execute`) — the user chooses by *how they launch it*. It is no longer true that "saha = the other pool."
2. **`/saha:execute` makes a saha run a *native interactive session* the watcher already observes.** Because the loop runs inside a normal Claude Code session (subagents via the Task tool), the kanban can watch it with the **exact machinery it uses for any interactive session** — Claude Code hooks / JSONL / statusline (`06-agent-state-detection.md`) — with **no saha-specific hook integration required**. Each phase's subagent call shows up as session/tool activity.
3. **The watcher-not-spawner constraint is now trivially satisfiable for autonomous work too.** The user runs `/saha:execute` in a Ghostty tab; the kanban *suggests* it but never types it. The loop bills the interactive pool the kanban already tracks. No subprocess, no Agent SDK pool, no spawning by the kanban. The only path that touches the capped pool is the explicit terminal `saha run`, which the kanban must still never auto-invoke.
4. **The kanban's job sharpens from "track the pool" to "route the launch."** Given live pool headroom, the board recommends *which command*: `/saha:execute` when interactive has headroom; `saha run` (or runner=Codex/Gemini) when it doesn't but API credit / another pool does. See `12-two-flow-scheduling-model.md`.

> **Verify-before-asserting flag:** `saha run`/`claude --print` → Agent-SDK-pool billing is per the 2026-06-15 research (verified today). `/saha:execute` → interactive-pool billing is per saha's own command docs + v0.9.0 release notes. Both deserve a one-time empirical re-check (watch each pool's counter while running each path) before the quota pillar costs them, since billing rules evolve.

---

## 4. The linkage: three integration surfaces saha already exposes

saha is unusually friendly to a watcher because it already emits machine-readable run state. A watcher can consume it with **zero coupling and zero spawning** — and for **`/saha:execute`** runs the loop *is* an interactive Claude Code session, so the watcher's existing Claude Code hooks/JSONL (`06-agent-state-detection.md`) already capture every phase with no saha-specific wiring. The three surfaces below matter most for **`saha run`** (subprocess) runs and for pool-tagged token accounting:

### Surface A — File-based state (poll or watch the filesystem)
- `ExecutionState` is persisted by `StateManager.save()` every phase: `current_phase` (enum `LoopPhase`: `IMPLEMENTATION`, `TEST_CRITIQUE`, `QA`, `CODE_QUALITY`, `MANAGER`, `DOD_CHECK`, `COMPLETED`, `FAILED`, `STOPPED`), `current_iteration`, and per-iteration records with `files_changed`, `files_added`, `dod_achieved`, `quality_passed`, `test_critique_passed`, `fix_info`.
- The Manager agent edits `user-stories/US-*.md` checkboxes and `implementation-plan/phase-*.md` status in place; `PlanProgressUpdater` writes a live execution-progress table + status line.
→ A board card for a saha task can be rendered **purely from disk**, with no API.

### Surface B — Push hooks (the preferred, no-polling path)
`AgenticLoop` fires a `HookRegistry` event at every transition: `loop_start`, `iteration_start`, `implementation_start`, `test_critique_start/failed`, `qa_start/failed`, `quality_start/failed`, `manager_start`, `dod_check_start`, `iteration_complete`, `loop_complete`, `loop_failed`, `loop_stopped`, `loop_error`.
→ The cleanest integration is a **saha hook that POSTs each transition to the kanban daemon** (mirrors how Claude Code HTTP hooks feed state detection in `06-agent-state-detection.md`). This is push, not poll — strictly better than the cmux model (cmux has *no* event stream yet; see `13-board-view-and-feature-parity.md`).

### Surface C — Per-phase, per-runner token telemetry (feeds the quota pillar directly)
`_record_phase_usage()` appends a `PhaseTokenUsage` to each iteration: `input/output/cache_read/cache_write/reasoning/total_tokens`, **`runner_name`**, duration. `saha/runners/usage.py` already normalizes provider-specific usage payloads into one schema.
→ saha **already measures exactly what the quota pillar needs**: tokens per phase, tagged by which runner (= which pool). The kanban does not need to re-derive saha's burn — it can ingest saha's own accounting and attribute it to the right pool. This is the single biggest "don't rebuild what saha already does" win.

---

## 5. How the two products compose (the workflow the user described)

The user's flow — *"saha long planning → task is ready → run it autonomously → review results"* — maps onto a board lifecycle where a **saha task is one species of card**:

```
Backlog ─(/saha:* planning)─▶ Planned/Ready ─(human launches /saha:execute OR saha run)─▶ Autonomous ─(DoD passes)─▶ Review ─▶ Done
                                   ▲                                                          │
                                   └──────────── kanban SUGGESTS launch + routes pool ────────┘
                                        (/saha:execute if interactive headroom; else saha run / Codex / Gemini)
```

- **Ready** = saha planning artifacts exist and `/saha:verify` is green. The board can read this state from the task README's progress table.
- **Autonomous** = a live run. Via **`/saha:execute`** it's a native interactive session the watcher observes directly (Claude Code hooks/JSONL); via **`saha run`** it's a subprocess observed through saha's own hooks/files. Either way the card shows `iteration N · phase QA · 2/5 stories done` and accumulated burn (Surface C), tagged by **which pool** it's spending.
- **Review** = DoD passed (`loop_complete` / `current_phase: completed`); the human reviews the diff and updated artifacts, then `/saha:resume` (or `saha resume`) for more, or moves the card to Done.
- The kanban's **backlog→capacity matchmaker** becomes saha-aware *and pool-routing*: "task-07 is saha-Ready; interactive window has headroom → suggest **`/saha:execute task-07`** (subscription-billed); if interactive is low but API credit is fresh → suggest `saha run task-07`" (suggest, never auto-dispatch).

Crucially, **not every card is a saha card.** The board also tracks the user's *interactive* Ghostty sessions (Flow B), which never go through saha. The board is the union; saha owns one lane. See `12-two-flow-scheduling-model.md` for the scheduling thesis.

---

## 6. Validated assumptions

| Assumption | Status | Evidence |
|---|---|---|
| saha and kanban overlap / compete | **False** | Different unit of work (one task vs. portfolio), different process model (spawner vs. watcher), different pool |
| saha is "just planning docs" | **False** | `saha run` is a full autonomous implement→QA→DoD loop with a hard DoD gate |
| saha only drives Claude headlessly (`saha run`) | **False (v0.9.0)** | `saha run` is headless (`claude --print` → Agent SDK pool), but `/saha:execute` runs the loop *in-session* → interactive pool |
| Flow A and the kanban are locked to opposite pools | **False (v0.9.0)** | A saha run is pool-flexible: `saha run` = API credit; `/saha:execute` = interactive subscription |
| The kanban would need to scrape saha's state | **False** | `/saha:execute` runs are observable via the same Claude Code hooks/JSONL the watcher already uses; `saha run` exposes file state + push hooks + normalized token telemetry |
| Auto-launching saha from the board is fine | **False** | Even `/saha:execute` should be suggest→human-confirm (the human types it in a tab); the board never spawns. Auto-`saha run` would also spend the capped Agent SDK pool |

## 7. Open questions (surface to user; not build-blocking)

- [ ] **How does the board offer launch?** Options: deep-link/prompt the user to type **`/saha:execute`** in a focused Ghostty tab (subscription-billed, watcher-pure), vs. a one-click `saha run` (API-billed subprocess). Both must be suggest→human-confirm; the board should label **which pool each spends** and route by live headroom. *User's product call.*
- [ ] **Integration surface priority:** start with Surface A (file watch — zero changes to saha) or invest in Surface B (add a kanban-reporting hook to saha — push, richer)? B is better long-term but couples a small amount of saha config.
- [ ] **Does the user want the kanban to also *show planning progress* (the `/saha:*` lifecycle), or only execution runs?** Showing both makes the board the front door to saha.
- [ ] **Re-verify the `claude --print` → Agent-SDK-pool billing** under subscription login before costing saha runs (see §3 flag).

## 8. Recommendation

1. **Frame the kanban as saha's cockpit, not its replacement.** Distinct value: portfolio breadth + cross-pool capacity planning. saha keeps single-task depth.
2. **Treat a saha task as a first-class card type** with a known lifecycle (Ready → Autonomous → Review) read from saha's on-disk state.
3. **Integrate via saha's hooks (push) for state and its `PhaseTokenUsage` for cost** — do not rebuild saha's accounting.
4. **Keep launching saha suggest-only, and route the launch by pool.** Prefer suggesting **`/saha:execute`** (in-session, subscription-billed, observed via existing Claude Code hooks) when interactive has headroom; fall back to `saha run` / Codex / Gemini when it doesn't. The board labels which pool each launch spends; it never types the command itself.
5. Carry the two-pool, two-flow framing into `task-description.md` via `/saha:task`, and into a design decision via `/saha:decide` ("saha integration: watch-and-suggest, never auto-spawn").

## References
- saha source: `runners/claude.py` (headless `--print`), `orchestrator/loop.py` (loop + hooks + `_record_phase_usage`), `runners/base.py`, `runners/usage.py`, installed `task-structure` skill.
- `10-claude-p-quota-change.md` (the 2026-06-15 split), [[watcher-not-spawner-quota-constraint]], [[project_vision]].
- `06-agent-state-detection.md` (hook-based state detection precedent), `07-orchestrator-landscape.md` (cmux/Vibe Kanban contrast).
