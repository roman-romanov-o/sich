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
- `--playwright`: use the `execution-qa-playwright` agent variant instead of
  `execution-qa` for the QA phase.

## What this command does

This command **is** the orchestrator. Each phase invokes a native Claude Code
subagent via the `Agent` tool. Runtime state is persisted to a YAML file between
phases so `/saha:resume` can pick up if interrupted.

**Format: saha/v2.** The task's spec is a LikeC4 model (`<task_path>/model/*.c4`)
and its tracking is `<task_path>/progress.yaml`. The loop enforces the two-file rule:

- `model/*.c4` is **frozen spec** from the moment this command starts. No phase —
  manager included — may edit a `.c4` file. The DoD gate verifies this.
- `progress.yaml` is the **only** task file any phase updates (AC ticks, test
  bindings, story/phase statuses, iteration history).

If the task folder has no `progress.yaml` with `format: saha/v2`, it's a legacy
markdown task — stop and tell the user to run it with the legacy path (`saha run`)
or re-plan it with the current `/saha:init` flow.

Loop shape (per iteration):

```
implementation → test_critique → qa → code_quality → manager → dod_check
```

Failure short-circuits the iteration: persist `fix_info` to state, run manager
(best-effort progress.yaml update), then start the next iteration. DoD success
ends the loop.

**Language-agnostic.** Before iterating, the loop resolves the project's
build/test/quality commands from a stack profile (Step 0) and passes them to each
phase. Each AC in progress.yaml declares its verification method
(`verify: automated | build | manual`); `manual` ACs are routed to a human and
never cause the loop to churn — they end it in `completed_pending_manual` instead.

## Execution recipe

Follow these steps. Persist state to disk after every phase so the loop is resumable.

### Step 0 — Resolve the project toolchain

Saha may be driving a Python, Swift, Node, Rust, or Go project. Resolve the commands
**once** at the start and stash them in `state.context.stack` so every phase uses them.

1. **Read `.sahaidachny/stack.yaml`** at the repo root if it exists. Use its
   `build.command`, `test.command`, `test.file_globs`, `quality.commands`,
   `quality.changed_files_only`, and `run.command`. An **empty string means "skip that
   gate"** (e.g. a UI-only target sets `test.command: ""`).
2. **Else auto-detect** from marker files at the repo root:

   | Marker | build | test | quality | run |
   |--------|-------|------|---------|-----|
   | `pyproject.toml` / `setup.py` | — | `pytest -q` | `ruff check`, `ty`, `complexipy` | `python -m <pkg>` |
   | `Package.swift` / `*.xcodeproj` | `swift build` | `swift test` | `swiftlint` | `swift run` |
   | `package.json` | `npm run build` (if defined) | `npm test` | `eslint`, `tsc --noEmit` | `npm start` |
   | `Cargo.toml` | `cargo build` | `cargo test` | `cargo clippy` | `cargo run` |
   | `go.mod` | `go build ./...` | `go test ./...` | `go vet`, `golangci-lint run` | `go run .` |

3. If neither is found, note it and let each phase inspect the repo / degrade gracefully.

Stash the resolved commands in `state.context.stack`:

```yaml
context:
  stack:
    build_command: "swift build"
    test_command: "swift test"
    test_file_globs: ["**/*Tests.swift"]
    quality_commands: ["swiftlint"]
    quality_changed_files_only: true
    run_command: "swift run"
  pending_manual_checks: []   # accumulated manual ACs awaiting human sign-off
```

### Step 1 — Resolve task, freeze the spec, load/create state

1. Resolve `task_id`:
   - If positional argument was provided, use it.
   - Else read `.sahaidachny/current-task`. Strip whitespace.
   - Else: ask the user which task to run.
2. Resolve `task_path` — find the directory whose folder name matches `task_id`
   under `docs/tasks/` (or wherever the project keeps tasks). It must contain
   `progress.yaml` with `format: saha/v2` (see above for legacy tasks). Read
   progress.yaml: it must have at least one story with ACs and at least one
   phase — if not, tell the user planning is incomplete (`/saha:status`).
3. **Freeze the spec.** Fingerprint the model:

   ```bash
   cd <task_path> && shasum model/*.c4
   ```

   Stash the output in `state.context.spec_fingerprint`. The DoD gate re-runs
   this and fails integrity if it changed. Set `status: executing` in
   progress.yaml (top-level).
4. State file path: `.sahaidachny/<task_id>-execution-state.yaml` (loop runtime
   state — separate from progress.yaml, which is the task's record).
5. **Always start fresh**: if state file exists, delete it. (`/saha:resume`
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
   context:
     stack: <resolved in Step 0>
     spec_fingerprint: <from step 3>
     pending_manual_checks: []
   last_agent_output: null
   ```

   Write it to the state file with `Write`.

### Step 2 — Iteration loop

Repeat until one of:
- `current_phase == completed` (DoD met, nothing pending)
- `current_phase == completed_pending_manual` (all automated/build ACs met; only
  `manual` ACs remain for human sign-off — this is a **success** terminal state, not churn)
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

Current plan phase: <state.context.current_plan_phase or "the first non-done phase in progress.yaml">
Project stack: <state.context.stack — test/build/run commands; do NOT assume Python>

Task folder: <task_path> (format saha/v2)
Read the spec and state directly from disk:
  - <task_path>/progress.yaml — stories, ACs (with verify methods), phases/steps.
    This is the authoritative work list.
  - <task_path>/model/*.c4 — the LikeC4 spec: task.c4 (context + affected files in
    metadata), stories.c4 (each story's step-by-step flow), contracts.c4 (the
    interfaces to honor — signatures in metadata contract blocks), decisions.c4
    (constraints), test-specs.c4 (scenario flows with Expected assertions).

SPEC IS FROZEN: never edit model/*.c4. Do not update progress.yaml either — the
manager phase owns it. You only write code and tests.

Honor each AC's verify method (from progress.yaml):
  - verify: automated — implement + write the test(s) its specs list describes
    (ts-* views in model/test-specs.c4), in the project's test framework.
  - verify: build — make sure the project compiles/launches.
  - verify: manual — implement the behavior, but do NOT try to write a headless
    test for it.

[If state.context.fix_info is set, include:]
## Fix Mode
Previous iteration failed. Focus on fixing:

<fix_info>

Run the project's test/build command (<state.context.stack.test_command or
build_command>) after each fix.

[Else:]
## TDD Cycle (use the project's language and test framework)
1. Interfaces/types from model/contracts.c4 metadata contract blocks (idiomatic
   for the stack — e.g. Pydantic in Python, structs/protocols in Swift).
2. Tests (Red) from model/test-specs.c4 scenarios — expect failure.
3. Implementation (Green) — make tests pass; run <state.context.stack.test_command>.

Return JSON at the end: {"files_changed": [...], "files_added": [...], "summary": "..."}
```

When the subagent returns, parse the trailing JSON block. Extract `files_changed`
and `files_added` into the iteration record. If the subagent errored (no JSON,
explicit failure), mark iteration as failed and go to Step 3.

Record step `{phase: implementation, status: completed, output_summary: <summary>}`.
Save state.

#### Phase B — Test Critique

Set `current_phase: test_critique`. Invoke `execution-test-critique` agent.

Prompt template:

```
Analyze test quality AND completeness for task: <task_id> (iteration <N>).
Task folder: <task_path> (format saha/v2)

Files changed this iteration:
<files_changed + files_added bullet list>

## Phase 1: Completeness
Cross-reference <task_path>/progress.yaml (every verify:automated AC and its
specs list) and <task_path>/model/test-specs.c4 (scenario Expected assertions)
against actual test files. Missing tests for significant automated ACs => fail.
verify:build and verify:manual ACs need NO tests — do not flag them.

## Phase 2: Quality
Flag over-mocking, mocking-the-SUT, placeholder tests, mock-only assertions,
missing E2E for key flows (the ts-e2e-* scenarios).

## Scoring
A/B = proceed; C/D/F = block QA.

Return JSON: {"critique_passed": bool, "test_quality_score": "A".."F",
  "tests_analyzed": int, "hollow_tests": int, "issues": [...],
  "uncovered_acceptance_criteria": [...], "uncovered_scenarios": [...],
  "summary": "...", "fix_info": "..." (if failed)}
```

If `critique_passed == false`: set `state.context.fix_info = <fix_info>`,
record step as failed, and go to Step 3. Otherwise, mark
`iteration.test_critique_passed = true`. Save state.

#### Phase C — QA

Set `current_phase: qa`. Choose subagent:
- if `--playwright` flag was passed, use `subagent_type: execution-qa-playwright`
- else use `subagent_type: execution-qa`

Prompt template:

```
Verify implementation for task: <task_id> (iteration <N>).
Task folder: <task_path> (format saha/v2)
Project stack: <state.context.stack>

Acceptance criteria live in <task_path>/progress.yaml (stories[].acceptance_criteria).
The expected behavior for each is spelled out in <task_path>/model/stories.c4
(story flows) and <task_path>/model/test-specs.c4 (Expected assertions).
Verify each AC is met by the current code, honoring its verify field:
  - automated (default): run <state.context.stack.test_command> and bind the AC to
    the relevant test(s). Report the binding as {"ac": "US-001.AC-1", "tests": [...]}.
  - build: run <state.context.stack.build_command> (and run_command if launching is
    implied). Pass if it compiles/launches cleanly — no behavioral assertion.
  - manual (+ manual_instructions): you CANNOT verify headlessly. Do NOT test it,
    do NOT put it in fix_info, do NOT fail the build for it. Record it in manual_checks.

Do NOT edit progress.yaml or model/*.c4 — report only; the manager phase records.

dod_achieved must reflect ONLY automated + build ACs. A manual AC pending human
sign-off is NOT a failure.

Return JSON: {"dod_achieved": bool, "fix_info": "..." (if not achieved),
  "ac_bindings": [{"ac": "US-001.AC-1", "tests": ["..."], "passed": bool}],
  "manual_checks": [{"criterion": "...", "instructions": "..."}],
  "test_output": "..." (optional)}
```

Accumulate any returned `manual_checks` into `state.context.pending_manual_checks`
(dedupe by criterion text) regardless of pass/fail. Stash `ac_bindings` in the
iteration record — the manager writes them into progress.yaml.

If `dod_achieved == false`: set `fix_info`, record step failed, go to Step 3.
Else `iteration.dod_achieved = true`. Save state.

#### Phase D — Code Quality

Set `current_phase: code_quality`. Invoke `execution-code-quality` agent.

Prompt template:

```
Analyze code quality for task: <task_id> (iteration <N>).
Project stack: <state.context.stack>

Files to analyze (changed this iteration):
<files_changed + files_added bullet list>

Run the project's resolved quality commands (<state.context.stack.quality_commands> —
e.g. ruff/ty/complexipy for Python, swiftlint for Swift, eslint/tsc for Node) on the
changed files only. If quality_commands is empty, skip this gate and pass. Filter
false positives and pre-existing issues. Only fail for genuine problems in the
changed code.

Return JSON: {"quality_passed": bool, "fix_info": "..." (if failed),
  "issues": [...], "files_analyzed": [...], "blocking_issues_count": int,
  "ignored_issues_count": int}
```

If `quality_passed == false`: set `fix_info`, record step failed, go to Step 3.
Else `iteration.quality_passed = true`. Save state.

#### Phase E — Manager

Set `current_phase: manager`. Invoke `execution-manager` agent.

Prompt template:

```
Record iteration <N> results for task: <task_id>.
Task folder: <task_path> (format saha/v2)
Current plan phase: <state.context.current_plan_phase or "auto-detect">

THE ONLY FILE YOU MAY EDIT IS <task_path>/progress.yaml. The LikeC4 model
(model/*.c4) is frozen spec — touching it fails the task's integrity gate.

Files changed this iteration:
<files_changed + files_added bullet list>

Iteration evidence:
  test_critique_passed: <bool>
  test_critique_score: <score or null>
  qa_passed: <bool>
  qa_ac_bindings: <ac_bindings JSON from the QA phase, or null>
  qa_fix_info: <string or null>
  quality_passed: <bool>
  quality_blocking_issues: <int or null>

Update progress.yaml:
- For each AC in qa_ac_bindings with passed:true — set its status: done and
  merge the bound test names into its tests: list.
- Set a story's status: done when all its automated+build ACs are done
  (manual ACs pending sign-off do not block story completion).
- Tick phase steps that the changed files + evidence show are implemented;
  set a phase status: done when all its steps are done.
- Append one record to iterations:
  { iteration: <N>, phase: <plan phase id>, result: passed|failed,
    notes: "<one-line summary>", files_changed: [...] }

Only mark items done that the evidence actually supports. When unsure, leave pending.

Return JSON: {"status": "success", "updates_made": [{"path":"progress.yaml","change":"...","verified":true}],
  "items_completed": [...], "items_remaining": [...], "failed_updates": [], "notes": "..."}
```

Record step. Save state. Manager failure is **non-fatal** — log and continue.

#### Phase F — DoD Check

Set `current_phase: dod_check`. Invoke `execution-dod` agent.

Prompt template:

```
Verify if task is COMPLETE: <task_id> (iterations completed: <N>).
Task folder: <task_path> (format saha/v2)
Project stack: <state.context.stack>

Ground truth sources:
  - <task_path>/progress.yaml — stories, ACs, verify methods, tests bindings, phases
  - a CLEAN test run (<state.context.stack.test_command>) — the verdict comes from
    the runner, not from status fields

## Integrity gate (check FIRST)
1. Spec frozen: run `cd <task_path> && shasum model/*.c4` and compare to:
   <state.context.spec_fingerprint>
   Any difference = integrity FAILURE (someone edited frozen spec).
2. Status honesty: every AC with status:done and verify:automated must have a
   non-empty tests: list whose tests exist and pass in the clean run. A done-AC
   with no real green test = integrity failure (checkmarks disagree with ground truth).

## Completion
A task is CODE-COMPLETE when every story's automated + build ACs are done per the
integrity rules above and all phases/steps are done.

ACs with verify: manual CANNOT be auto-checked — they need human sign-off. Do NOT
treat a pending manual AC as "incomplete work" that blocks the loop. List it under
pending_manual_checks (with its manual_instructions). A story whose only remaining
ACs are manual is code-complete.

Do NOT edit any file. Report only.

Return JSON: {"task_complete": bool (code-complete per above),
  "integrity_ok": bool, "integrity_violations": [...],
  "pending_manual_checks": [{"criterion": "...", "instructions": "..."}],
  "remaining_items": [...] (genuine automated/build gaps only), "reasoning": "..."}
```

Merge the agent's `pending_manual_checks` into `state.context.pending_manual_checks`
(dedupe by criterion).

- If `integrity_ok == false`: this is fatal — set `current_phase: failed`,
  `error_message` from the violations, save, end the loop, and surface the
  violations to the user (restore `model/*.c4` from git if the spec was edited).
- If `task_complete == true` and `state.context.pending_manual_checks` is **empty**:
  set `current_phase: completed`, `completed_at: <now>`; set progress.yaml
  top-level `status: completed`. Save. **End the loop.**
- If `task_complete == true` and there **are** pending manual checks: set
  `current_phase: completed_pending_manual`, `completed_at: <now>`; set
  progress.yaml `status: completed_pending_manual`. Save. **End the loop** —
  the work is code-complete; the manual checklist goes to the human (Step 4).
  Do NOT iterate further trying to "pass" manual ACs.
- If `task_complete == false`: record what's remaining (real automated/build gaps),
  continue to next iteration (go back to Step 2).

### Step 3 — Manager on iteration stop

When a phase short-circuits the iteration (B/C/D failed):
1. Best-effort: still invoke `execution-manager` with the same prompt but
   include `stopped_at_phase: <phase>` and `stop_reason: <fix_info>` so it
   conservatively records partial progress (still progress.yaml ONLY —
   typically just the iterations append with result: failed).
2. Don't fail the loop — the next iteration will retry with `fix_info`.

### Step 4 — Termination

When the loop ends, print a clear summary:

```
═══════════════════════════════════════════════
SAHA EXECUTION FINISHED
  Task: <task_id>
  Final phase: <current_phase>
  Iterations: <current_iteration> / <max_iterations>
  [if completed]                 DoD: ✓ Met
  [if completed_pending_manual]  DoD: ✓ Code-complete — manual sign-off pending
  [if failed/stopped]            Reason: <error_message>
═══════════════════════════════════════════════
```

If `current_phase == completed_pending_manual`, also print the human checklist so the
user knows exactly what to verify by hand:

```
MANUAL VERIFICATION REQUIRED (no headless test can confirm these):
  ☐ <criterion> — <instructions>
  ☐ ...
Sign these off manually; the code work for this task is complete.
```

If the user hits Ctrl-C mid-loop, that just stops the current slash command —
the YAML state file is on disk, so `/saha:resume <task-id>` will pick up.

## Notes

- **Two-file rule, enforced**: `model/*.c4` frozen (fingerprint-checked at DoD),
  `progress.yaml` written by the manager phase only. Implementer/QA/critique/DoD
  read both, edit neither.
- **No artifact pre-bundling**: each subagent reads what it needs from disk.
- **JSON parsing**: subagents return free text followed by a JSON block.
  Extract the last fenced ```json ... ``` (or standalone `{...}` block) at
  the end of their output. If parsing fails, treat the phase as failed with
  fix_info = "agent returned no parseable JSON: <first 500 chars>".
- **Plan phase tracking**: set `state.context.current_plan_phase` to the first
  phase in progress.yaml whose status isn't `done` so the implementer focuses there.
- **No subprocess**: do NOT shell out to `claude` from Bash. The whole loop
  runs in this session.
