---
description: Run the agentic execution loop for a task (subscription-billed, no subprocess)
argument-hint: [task-id] [--max-iter=N] [--playwright]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task
---

# Saha Execute

Run the full agentic execution loop for a task **inside this Claude Code session**.
All subagent calls go through the active session, so usage is billed against the
current Claude subscription — no `claude -p` subprocess, no Agent SDK.

## Arguments

- **task-id** (optional, positional): e.g. `task-01-foo`. If omitted, read from
  `.sahaidachny/current-task`. If that file is missing too, ask the user.
- `--max-iter=N`: cap iterations (default 5).
- `--playwright`: use the `execution-qa-playwright` agent variant for the QA phase
  (browser UI). Default QA is `execution-qa-native` (this project's UI is native
  AppKit, verified by `swift test` + `screencapture`, not a browser).

## What this command does

This command **is** the orchestrator. It runs the same loop as `saha/orchestrator/loop.py`,
but expressed as a recipe Claude follows. Each phase invokes a native Claude Code subagent
via the `Agent` tool. State is persisted to a YAML file between phases so `/saha:resume`
can pick up if interrupted.

Loop shape (per iteration):

```
implementation → [integrity guard] → test_critique → qa → code_quality → manager → dod_check
```

The acceptance contract (`user-stories/`, `test-specs/`) is **frozen at loop start**.
The integrity guard fails fast if the implementer edits it. `dod_check` is the
**authoritative, executable** gate: it runs its own clean test suite, binds every
acceptance criterion to a real passing test via the frozen coverage matrix, and
checks integrity invariants — it does **not** trust the `[x]` marks the swarm wrote.
This is what lets the loop run unattended; the human validates the spec once, not
every output.

Failure short-circuits the iteration: persist `fix_info` to state, run manager (best-effort
cleanup of artifact statuses), then start the next iteration. DoD success ends the loop.
A tampered-spec integrity failure is **fatal** (ends the loop) — the contract must be
re-frozen via planning before execution can be trusted again.

## Project adaptation — multi-runtime (agentic-coding-kanban)

> **This project is NOT a single-runtime Python repo.** It ships a **Python logic
> core** (`src/mission_control/**`, verified by `pytest`) *and* a **Swift/AppKit
> libghostty app** (`app/`, verified by `swift test` + headless `ghostling-probe`
> smokes), with a residue of genuinely **pixel-level** acceptance criteria (a
> window *renders*, a drill-in *feels* instant) that only a human eye can confirm.
> The stock Python-only loop would run `pytest`, see green, and declare a **false
> pass** while the Swift half went unverified — and it would **churn to max-iter**
> on the pixel ACs (an implementer pass cannot turn a pixel into a green test).
> This adaptation fixes both.

**Routing rules used throughout this recipe:**

1. **Verification agents are the multi-runtime variants.** Phase C uses
   `execution-qa-native`, Phase D uses `execution-code-quality-native`, Phase F
   uses `execution-dod-native`. (The `--playwright` flag still selects
   `execution-qa-playwright` for browser-UI work; this project's UI is native
   AppKit, so the native QA agent and `screencapture` are the default.)
2. **The baseline freeze is dual** — a `pytest` collected count **and** a
   `swift test` count (see Step 1.5). Deleting tests in *either* runtime to force
   a green is an integrity violation.
3. **The DoD gate binds each AC to evidence in its own runtime** — a pytest node,
   a `swift test` case, a probe smoke, or (for pixel ACs) a captured screenshot.
4. **Pixel residue does not churn the loop.** When `execution-dod-native` reports
   `machine_gates_complete: true` + `awaiting_visual_signoff: true`, the loop
   **pauses for one human visual sign-off** (terminal state
   `awaiting_visual_signoff`) instead of spending another iteration. This is the
   loop's single legitimate human checkpoint — the same "human validates the spec
   once, the machine validates the rest" philosophy, extended to the visual layer.

Everything else (the frozen contract, the integrity guard, the
trust-ground-truth-not-checkmarks discipline) is unchanged.

## Execution recipe

Follow these steps. Persist state to disk after every phase so the loop is resumable.

### Step 1 — Resolve task and load/create state

1. Resolve `task_id`:
   - If positional argument was provided, use it.
   - Else read `.sahaidachny/current-task`. Strip whitespace.
   - Else: ask the user which task to run.
2. Resolve `task_path` — find the directory whose folder name matches `task_id`
   under `docs/tasks/` (or wherever the project keeps tasks; check
   `pyproject.toml` `[tool.saha]` if unsure). It must contain `task-description.md`.
   If not found, error out.
3. State file path: `.sahaidachny/<task_id>-execution-state.yaml`.
4. **Always start fresh**: if state file exists, delete it. (`/saha:resume`
   is the entry point for continuation.) Create a new state document:

   ```yaml
   task_id: <task_id>
   task_path: <task_path>
   current_phase: idle
   current_iteration: 0
   max_iterations: <from --max-iter or 5>
   started_at: <ISO 8601 now>
   completed_at: null
   error_message: null
   iterations: []
   context: {}
   last_agent_output: null
   ```

   Write it to the state file with `Write`.

5. **Freeze the spec baseline** (anti-gaming invariant). The user stories and
   test specs are the acceptance contract; they are **immutable for the duration
   of this run**. Record a content manifest so any mid-loop edit is detected, and
   a collected-test count so tests can't be deleted to force a green:

   ```bash
   # per-file sha256 of every contract file (the frozen spec)
   find <task_path>/user-stories <task_path>/test-specs -name '*.md' \
     -not -name 'README.md' -not -name '_TEMPLATE_*' -print0 \
     | sort -z | xargs -0 shasum -a 256
   # baseline test counts (monotonicity floor) — BOTH runtimes
   pytest --co -q -p no:cacheprovider 2>/dev/null | grep -c '::'          # Python
   ( cd app && swift test list 2>/dev/null | grep -c '/' )                # Swift
   ```

   Store the manifest under `context.spec_baseline` (map of `path → sha256`), the
   pytest count under `context.tests_collected_baseline`, and the swift count
   under `context.swift_tests_collected_baseline`. If `app/` is absent (a
   Python-only task), set the swift baseline to `0`. If `<task_path>` is under
   git, also stash `git rev-parse HEAD` into `context.git_baseline`. Save state.

   > Why: the DoD gate derives "done" from a clean test run bound to this frozen
   > matrix — never from `[x]` marks. Freezing the contract is what stops the
   > swarm from moving the goalposts to declare victory.

### Step 2 — Iteration loop

Repeat until one of:
- `current_phase == completed` (DoD met)
- `current_phase == failed` (fatal)
- `current_iteration >= max_iterations`
- User interrupts

For each iteration:

1. Increment `current_iteration`. Append a new iteration record to `iterations`:

   ```yaml
   - iteration: <N>
     started_at: <now>
     steps: []
     test_critique_passed: false
     dod_achieved: false
     quality_passed: false
     fix_info: null
     files_changed: []
     files_added: []
   ```

   Save state.

2. Run each phase below. After **every** phase, update the iteration record
   and save state. If a phase short-circuits the iteration, jump to **Manager
   on stop** (Step 3), then loop.

#### Phase A — Implementation

Set `current_phase: implementation`, save state.

Invoke the `execution-implementer` subagent via the `Agent` tool with `subagent_type: execution-implementer`.

Prompt template:

```
Implement task: <task_id> (iteration <N>).

Current plan phase: <state.context.current_plan_phase or "any READY phase">

Task folder: <task_path>
Read the task artifacts directly from disk:
  - <task_path>/task-description.md
  - <task_path>/user-stories/*.md (focus on Ready/In Progress)
  - <task_path>/code-changes/*.md
  - <task_path>/test-specs/**/*.md
  - <task_path>/implementation-plan/phase-*.md (active phase only)

[If state.context.fix_info is set, include:]
## Fix Mode
Previous iteration failed. Focus on fixing:

<fix_info>

Run tests after each fix.

[Else:]
## TDD Cycle
1. Interfaces from code-changes — Pydantic models, Protocol classes.
2. Tests (Red) from test-specs — pytest, expect failure.
3. Implementation (Green) — make tests pass, run them.

Return JSON at the end: {"files_changed": [...], "files_added": [...], "summary": "..."}
```

When the subagent returns, parse the trailing JSON block. Extract `files_changed`
and `files_added` into the iteration record. If the subagent errored (no JSON,
explicit failure), mark iteration as failed and go to Step 3.

Record step `{phase: implementation, status: completed, output_summary: <summary>}`.
Save state.

#### Integrity guard — specs are frozen

Immediately after implementation, before spending any QA/quality cycles, verify
the implementer did not touch the acceptance contract. Recompute the spec
manifest and compare to `context.spec_baseline`:

```bash
find <task_path>/user-stories <task_path>/test-specs -name '*.md' \
  -not -name 'README.md' -not -name '_TEMPLATE_*' -print0 \
  | sort -z | xargs -0 shasum -a 256
```

If any contract file's hash differs from the baseline, the goalposts moved.
Do **not** continue the iteration: set `current_phase: failed`,
`error_message: "Frozen spec modified during execution: <files>. Re-freeze via
planning, then re-run."`, save state, and **end the loop** (this is fatal, not a
retry — a moved contract invalidates every downstream result). The implementer
may freely edit `src/` and `tests/`, never `user-stories/` or `test-specs/`.

#### Phase B — Test Critique

Set `current_phase: test_critique`. Invoke `execution-test-critique` agent.

Prompt template:

```
Analyze test quality AND completeness for task: <task_id> (iteration <N>).
Task folder: <task_path>

Files changed this iteration:
<files_changed + files_added bullet list>

## Phase 1: Completeness
Cross-reference acceptance criteria, code-changes, and test-specs against
actual test files. Missing tests for significant ACs/code-changes => fail.

## Phase 2: Quality
Flag over-mocking, mocking-the-SUT, placeholder tests, mock-only assertions,
missing E2E for key flows.

## Scoring
A/B = proceed; C/D/F = block QA.

Return JSON: {"critique_passed": bool, "test_quality_score": "A".."F",
  "tests_analyzed": int, "hollow_tests": int, "issues": [...],
  "uncovered_acceptance_criteria": [...], "uncovered_code_changes": [...],
  "missing_test_specs": [...], "summary": "...", "fix_info": "..." (if failed)}
```

If `critique_passed == false`: set `state.context.fix_info = <fix_info>`,
record step as failed, and go to Step 3. Otherwise, mark
`iteration.test_critique_passed = true`. Save state.

#### Phase C — QA

Set `current_phase: qa`. Choose subagent:
- if `--playwright` flag was passed, use `subagent_type: execution-qa-playwright`
- else use `subagent_type: execution-qa-native` (multi-runtime — see Project adaptation)

Prompt template:

```
Verify implementation for task: <task_id> (iteration <N>).
Task folder: <task_path>

Files changed this iteration:
<files_changed + files_added bullet list>

Acceptance criteria live in <task_path>/user-stories/*.md. Read them, then RUN
THE RUNTIME(S) THE CHANGED FILES TOUCH:
  - Python (src/**, tests/**): pytest -v --tb=short -p no:cacheprovider
  - Swift (app/**): (cd app && swift build) && (cd app && swift test)
  - pool-firewall / PTY-read ACs: ghostling-probe smokes (exit code is the assertion)
  - pixel ACs (window renders / drill-in feels instant): capture a screenshot to
    app/.artifacts/ and report it as needs_human_visual — do NOT auto-pass it.

Do not approve a runtime you did not run. Pixel ACs do not block this
per-iteration gate but must be reported with their artifact.

Return JSON: {"dod_achieved": bool, "runtimes_run": [...],
  "test_results": {...}, "visual_checks": [...], "fix_info": "..." (if not achieved)}
```

If `dod_achieved == false`: set `fix_info`, record step failed, go to Step 3.
Else `iteration.dod_achieved = true`. Carry any `visual_checks` forward in the
iteration record (the DoD gate will need the artifacts). Save state.

#### Phase D — Code Quality

Set `current_phase: code_quality`. Invoke `execution-code-quality-native` agent
(routes each changed file by extension — see Project adaptation).

Prompt template:

```
Analyze code quality for task: <task_id> (iteration <N>).

Files to analyze (changed this iteration):
<files_changed + files_added bullet list>

Route each file by extension:
  - .py  → ruff check --fix + ruff format, then ruff/ty/complexipy
  - .swift → (cd app && swift build) compiler warnings + repo rules
            (functions ≲50 lines, single-responsibility, imports at top);
            note that swiftlint/swift-format are not installed
  - .c/.h → swift build compiler warnings
Filter false positives and pre-existing issues (git diff). Only fail for genuine
problems in the changed code.

Return JSON: {"quality_passed": bool, "fix_info": "..." (if failed),
  "issues": [...], "files_analyzed": [...], "routing": {...},
  "blocking_issues_count": int, "ignored_issues_count": int, "tool_notes": [...]}
```

If `quality_passed == false`: set `fix_info`, record step failed, go to Step 3.
Else `iteration.quality_passed = true`. Save state.

#### Phase E — Manager

Set `current_phase: manager`. Invoke `execution-manager` agent.

Prompt template:

```
Update task artifacts after iteration <N> for task: <task_id>.
Task folder: <task_path>
Current plan phase: <state.context.current_plan_phase or "auto-detect">

Files changed this iteration:
<files_changed + files_added bullet list>

Iteration evidence:
  test_critique_passed: <bool>
  test_critique_score: <score or null>
  qa_passed: <bool>
  qa_fix_info: <string or null>
  quality_passed: <bool>
  quality_blocking_issues: <int or null>

Edit user-stories and implementation-plan files on disk to:
- check off newly completed acceptance criteria with [x]
- update story Status when all its ACs are met
- mark completed plan phases

Only mark items done that are actually implemented. When unsure, leave pending.

Return JSON: {"status": "success", "updates_made": [{"file":"...","change":"...","verified":true}],
  "items_completed": [...], "items_remaining": [...], "failed_updates": [], "notes": "..."}
```

Record step. Save state. Manager failure is **non-fatal** — log and continue.

#### Phase F — DoD Check (authoritative, executable)

Set `current_phase: dod_check`. Invoke `execution-dod-native` agent (multi-runtime
authoritative gate — see Project adaptation).

This is the authoritative gate. It runs its **own clean test suites in every
runtime** (`pytest` AND `swift test` AND the probe smokes) and derives completion
from the frozen coverage matrix + integrity invariants — it does **not** trust the
`[x]` marks the manager wrote. Pass it **both** baselines so it can check
integrity in either runtime. (QA in Phase C is fast per-iteration feedback and can
be fooled; DoD is the final independent verdict — keep both.)

Prompt template:

```
Decide if the task is COMPLETE: <task_id> (iterations completed: <N>).
Task folder: <task_path>

You are the authoritative MULTI-RUNTIME executable gate. Trust ground truth in
EVERY runtime the repo ships, not checkmarks. Never pass while a runtime went
unrun (50 green pytest with swift test unexecuted is a FALSE pass).

Frozen contract (do not let it move):
  spec_baseline: <context.spec_baseline as path → sha256 map>
  tests_collected_baseline: <context.tests_collected_baseline>          # pytest
  swift_tests_collected_baseline: <context.swift_tests_collected_baseline>

Visual artifacts captured by QA this run (for pixel ACs):
  <iteration.visual_checks bullet list, or "none">

Verify the gates and return per-runtime evidence:
  1. Coverage — every AC in test-specs/README.md binds to >=1 pytest node, OR
     >=1 swift test case, OR a probe smoke, OR (pixel ACs) a captured screenshot.
  2. Green — run pytest (unfiltered), (cd app && swift test), and the bound probe
     smokes yourself; every bound item passes / exits as expected. A skip/xfail/
     disabled bound test is NOT green.
  3. Integrity — specs match spec_baseline; pytest count >= its baseline AND swift
     count >= its baseline (dual); no bound test skipped in either runtime.
  4. Quality — the latest iteration's quality_passed is true.

Classify pixel-only ACs (window renders, drill-in feels instant) as
needs-human-visual: require a captured screenshot, list under
visual_signoff_required, and DO NOT auto-pass them.

Cross-check (do not trust): if user-stories say Status: Done / [x] but ground
truth disagrees, report it under marker_conflicts.

task_complete = true ONLY if all machine gates pass AND there is no unresolved
visual residue. If the machine gates pass but pixel ACs remain, return
task_complete:false, machine_gates_complete:true, awaiting_visual_signoff:true.
If you cannot bind the matrix or a runtime would not run, task_complete:false,
confidence:"low".

Return JSON: {"task_complete": bool, "machine_gates_complete": bool,
  "awaiting_visual_signoff": bool, "confidence": "...", "gates": {...},
  "test_runs": {...}, "visual_signoff_required": [...], "marker_conflicts": [...],
  "remaining_items": [...], "fix_info": "..." (if not complete), "reasoning": "..."}
```

Handle the verdict:

- `task_complete == true`: set `current_phase: completed`, `completed_at: <now>`.
  Save state. **End the loop.**
- `task_complete == false` **with an integrity violation** (`gates.integrity.passed
  == false`): the contract was tampered with (in *either* runtime — e.g. the swift
  suite shrank) — set `current_phase: failed`, `error_message: <reasoning>`, save
  state, and **end the loop**. This is fatal; re-freezing requires re-planning.
- `task_complete == false` **with `machine_gates_complete == true` and
  `awaiting_visual_signoff == true`**: every assertable gate passed and only
  pixel ACs remain — **do NOT spend another iteration** (an implementer pass
  cannot turn a pixel into a green test). Set `current_phase:
  awaiting_visual_signoff`, store `context.visual_signoff_required` from the
  verdict, save state, and **end the loop** (see Step 4 for the sign-off
  checklist the human approves).
- `task_complete == false` otherwise: set `state.context.fix_info = <fix_info>`,
  record `remaining_items` and any `marker_conflicts`, and continue to the next
  iteration (go back to Step 2). Feeding `fix_info` forward focuses the next
  implementer pass on the unbound/ungreen ACs specifically (in whichever runtime).

### Step 3 — Manager on iteration stop

When a phase short-circuits the iteration (B/C/D failed):
1. Best-effort: still invoke `execution-manager` with the same prompt but
   include `stopped_at_phase: <phase>` and `stop_reason: <fix_info>` so it
   conservatively records partial progress.
2. Don't fail the loop — the next iteration will retry with `fix_info`.

### Step 4 — Termination

When the loop ends, print a clear summary:

```
═══════════════════════════════════════════════
SAHA EXECUTION FINISHED
  Task: <task_id>
  Final phase: <current_phase>
  Iterations: <current_iteration> / <max_iterations>
  [if completed]                 DoD: ✓ Met (all runtimes green)
  [if awaiting_visual_signoff]   DoD: ◐ Machine gates met — awaiting human visual sign-off
  [if failed/stopped]            Reason: <error_message>
═══════════════════════════════════════════════
```

**If `current_phase == awaiting_visual_signoff`**, the machine did everything it
can: every assertable AC is green in every runtime, and the only residue is
pixel-level. Print the sign-off checklist for the human to approve — this is the
loop's one legitimate human checkpoint, not a failure:

```
HUMAN VISUAL SIGN-OFF NEEDED (machine-verified everything else):
  □ <ac> — <what to verify> — artifact: <screenshot path>
  □ ...
Approve all → the task is complete. Reject any → describe the visual defect and
re-run /saha:execute (it becomes fix_info for the next implementer pass).
```

If the user hits Ctrl-C mid-loop, that just stops the current slash command —
the YAML state file is on disk, so `/saha:resume <task-id>` will pick up.

## Notes

- **No artifact pre-bundling**: each subagent reads what it needs from disk.
  Less efficient than the Python `ArtifactBundler` but simpler and still cheap
  (Read is cached, subagents are focused).
- **JSON parsing**: subagents return free text followed by a JSON block.
  Extract the last fenced ```json ... ``` (or standalone `{...}` block) at
  the end of their output. If parsing fails, treat the phase as failed with
  fix_info = "agent returned no parseable JSON: <first 500 chars>".
- **Plan phase tracking**: if you can detect a current `Status: In Progress` /
  `Ready` phase in `<task_path>/implementation-plan/phase-*.md`, set
  `state.context.current_plan_phase` so the implementer focuses there.
- **No subprocess**: do NOT shell out to `claude` from Bash. The whole loop
  runs in this session.
