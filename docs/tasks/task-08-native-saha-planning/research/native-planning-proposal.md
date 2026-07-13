# Native saha planning in the kanban UI — research & proposal

**Status:** Draft (research, pre-`/saha:init`)
**Date:** 2026-07-05
**Goal:** make the saha planning step as productive as possible by driving it from the app instead of raw CLI: proactive step guidance, a real doc viewer (markdown + mermaid), and chat-during-planning.

---

## 1. What we learned (ground truth from both repos)

### saha side (`~/MyProjects/sahaidachny`)

- **Planning is not Python — it's Claude slash commands.** `/saha:init → task → research → stories → decide → contracts → test-specs → plan → verify` are markdown recipes executed *inside an interactive Claude session*, most using `AskUserQuestion`. There is no Python API for planning steps.
- **Planning progress is markdown markers, no JSON.** README "Planning Progress" table (`Pending`/`Done`), per-artifact `**Status:** Draft|Review|Approved` lines, `- [ ]` acceptance criteria. `/saha:status` and Python `TaskVerifier` (`saha/verification/checker.py`) both infer state by scanning the folder.
- **Execution state IS machine-readable:** `.sahaidachny/<task-id>-execution-state.yaml` (pydantic `ExecutionState`: phase, iteration, tokens, files changed) — written at every phase via `StateManager.save()`, a single choke point. `.sahaidachny/current-task` holds the active task folder name.
- **Extension points:** Typer CLI (`saha/commands/execution.py`), hook system (`saha/hooks/`), `TaskVerifier` returns structured `CheckResult`s already.

### app side (this repo)

- Two altitudes: board (`BoardShell`) and drill-in (`DrillInPanel` = terminal + 300pt `DrillInSidebar`). Full-window overlay mechanics (`drill()/returnToBoard()`) are proven and reusable for a third surface.
- **No markdown rendering exists anywhere.** Chrome is layer-backed `NSTextField` + `NSStackView` (the only proven render path on our theme); no `NSTextView`, no `WKWebView` (task-05 forbade a webview *for the diff panel*).
- **Cards don't know about `docs/tasks/task-XX/` folders.** `BoardCard` keys on sessionID/projectDir. The projectDir → task-folder bridge doesn't exist yet.
- task-06 (proactive advisor, in Review) already models saha readiness as a DAG (`PLAN → PLAN_VERIFY → … → SUGGEST_LAUNCH`) and defines `PlanAttestation`. **The planning surface proposed here is the producer of the state task-06 consumes** — both must read the same artifact model.

### The unlock

Saha planning steps are interactive Claude sessions; our app *is* an interactive Claude terminal host. So "chat during planning" is not a new chat widget — it's the drilled-in terminal running `/saha:task`, with the app typing the next slash command for you and rendering the docs the session writes, live. No new agent spawning, no pool-firewall issue (we type into a session the user owns; `claude -p` stays banned).

---

## 2. Proposed capability: Planning Mode (Altitude-2)

A full-window overlay (sibling of `DrillInPanel` in `BoardShell`), entered from a saha-flow card or a "Plan a task" action. Three panes:

```
┌────────────┬──────────────────────────┬──────────────────────┐
│ STEPPER    │ DOC VIEWER               │ PLANNING TERMINAL     │
│ ○ init  ✓  │ (markdown + mermaid,     │ (embedded Claude      │
│ ○ task  ✓  │  renders the artifact    │  session; the chat.   │
│ ● stories… │  the current step is     │  App pre-types the    │
│ ○ decide   │  producing, live-reload  │  next /saha:* cmd,    │
│ ○ plan     │  on file change)         │  user hits Enter)     │
│ ○ verify   │                          │                       │
└────────────┴──────────────────────────┴──────────────────────┘
```

### 2a. Proactive step driving (the stepper)

- A `PlanningStateReader` (Swift, GhostlingCore) scans `docs/tasks/task-XX/` with the same glob table `/saha:status` uses and parses `**Status:**` markers + README progress table → `PlanningState` (per-step: pending / in-progress / done, artifact paths).
- Reuses the existing `FileWatcher` (sub-250ms) on the task folder → the stepper and doc viewer update live *as Claude writes the docs*.
- The stepper highlights the next incomplete step; clicking it types the corresponding `/saha:xxx` into the planning terminal PTY (user presses Enter — suggest-then-confirm, consistent with task-06's suggest-only invariant).
- When all steps are done + `/saha:verify` passed → surface the launch hand-off ("run `/saha:execute` here or `saha run <id>`"), which is exactly task-06's `SUGGEST_LAUNCH`.

### 2b. Doc viewer (markdown + mermaid)

The one genuinely new render capability. **Decision: no webview — fully native.**

- **Markdown:** apple/swift-markdown (SPM) parses full GFM (tables, task-lists — saha docs are heavy on both) → a small walker emitting `NSAttributedString` styled from `BoardTheme` tokens → one scrollable read-only `NSTextView`. Pixel-consistent with the app theme, instant, no JS, and the walker is pure-function testable. Checkboxes as ☐/☑ glyphs; `**Status:**` lines styled as native pills.
- **Mermaid:** on-demand shell-out to `mmdc` (mermaid-cli, user-installed optional tool — node/puppeteer, never bundled) → SVG/PNG → inline `NSImage` attachment, cached by content hash of the block. If `mmdc` is absent, degrade to a syntax-highlighted code block with an install hint. Saha docs barely use mermaid today, so the degraded mode is fine at v1.

This keeps the task-05 "no webview" rule intact repo-wide — no DD exception needed.

### 2c. Chat during planning

Free: the right pane is a normal `TerminalSurface` session (registered via `SessionRegistry`, appears on the board like any session). The user converses with `/saha:task`'s `AskUserQuestion` prompts natively. Drill-out/drill-in back-pressure handling (board pump) already covers it.

### 2d. Saha-flow at task creation (primary card ↔ task-folder binding)

Creation-time, not inference-time: a "New task" affordance asks which flow (the board already distinguishes `CardFlow.a` saha vs `.b` interactive). Choosing saha shows a picker:
- **existing** `docs/tasks/task-*/` folders, each with its planning-progress chip (e.g. `plan 5/8`), or
- **create new** → runs saha's own `init_task.sh` (auto-numbers, slugifies, writes `.sahaidachny/current-task`) and drops straight into Planning Mode at step 1.

The card is born with an explicit `taskFolder` binding on `BoardCard`. Fallback for cards created outside the app: `TaskFolderIndex` — enumerate `docs/tasks/task-*/` in the projectDir + read `.sahaidachny/current-task`. Shared foundation with task-06.

---

## 3. Proposed saha-side changes (we control both repos)

Ordered by value/effort:

1. **`saha status --json`** — in `_status_command` (`saha/commands/execution.py:439-489`), emit `state.model_dump(mode="json")`. One flag. Gives the app execution state without hand-parsing YAML (though watching the YAML also works and is already stable).
2. **`saha plan-status <task-id> --json`** — new thin Typer command wrapping `TaskVerifier.verify()` → JSON of `CheckResult`s + a derived `next_step`. This makes planning state *officially* machine-readable instead of the app replicating the glob/marker heuristics. The Swift `PlanningStateReader` then becomes a fallback for repos without saha installed.
3. **Planning-state contract doc** in saha (`docs/`): freeze the `**Status:**` values, README table format, and glob table as a versioned contract, since two repos + task-06 now parse them.
4. *(later)* **UI event hook**: a `saha/hooks/` hook (or a tee in `StateManager.save()`) appending phase transitions to `~/.ghostling/events.jsonl` — execution loop progress would flow through the app's existing hook pipeline with zero new plumbing. Not needed for planning mode v1 (file-watch covers it).

Explicitly **not** proposed: a saha HTTP API, a planning Python API, or moving planning logic out of slash commands. The recipes are the product; the app hosts them.

---

## 4. Slicing (candidate stories for `/saha:stories`)

1. **US-A Saha-flow task creation:** flow choice at card creation; existing-task picker + create-new via `init_task.sh`; `BoardCard.taskFolder` binding; progress chip on board. (Foundational.)
2. **US-B Stepper + state reader:** `PlanningStateReader` + file-watch live updates; pure logic → fully `swift test`-able.
3. **US-C Planning altitude:** the 3-pane overlay wired into `BoardShell`, terminal pane = normal registered session; step-click pre-types command.
4. **US-D Doc viewer:** swift-markdown → NSAttributedString walker + NSTextView; mermaid via optional `mmdc` shell-out with graceful degrade.
5. **US-E saha `plan-status --json`** (sahaidachny repo, pytest-covered).
6. **US-F Launch hand-off:** verify-passed → suggest `/saha:execute` / `saha run` per pool state (integrates with task-06 later).

Risks: (1) NSAttributedString walker fidelity for complex tables — cap table styling at v1 (monospace grid fallback is acceptable); (2) marker-parsing fragility → mitigated by US-E making saha the source of truth; (3) overlap with task-06 → keep this task UI-only, emit the same artifact-derived state task-06's contracts expect.

---

## 5. TL;DR

Don't build a chat UI or a planning engine — saha planning already *is* a chat (interactive slash commands). Build: **saha-flow choice at task creation** (pick or init a task folder, card bound to it), plus a **planning altitude** that watches the folder, shows a live stepper + natively rendered docs (swift-markdown → NSTextView; mermaid via optional `mmdc`), and pre-types the next `/saha:*` command into an embedded terminal the user talks to. On the saha side, add one `--json` planning-status command so state parsing has an official source of truth. No webview anywhere.
