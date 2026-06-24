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

This command **is** the orchestrator. It runs the same loop as `saha/orchestrator/loop.py`,
but expressed as a recipe Claude follows. Each phase invokes a native Claude Code subagent
via the `Agent` tool. State is persisted to a YAML file between phases so `/saha:resume`
can pick up if interrupted.

Loop shape (per iteration):

```
implementation → test_critique → qa → code_quality → manager → dod_check
```

Failure short-circuits the iteration: persist `fix_info` to state, run manager (best-effort
cleanup of artifact statuses), then start the next iteration. DoD success ends the loop.

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
- else use `subagent_type: execution-qa`

Prompt template:

```
Verify implementation for task: <task_id> (iteration <N>).
Task folder: <task_path>

Acceptance criteria live in <task_path>/user-stories/*.md. Read them and
verify each is met by the current code. Run pytest if relevant.

Return JSON: {"dod_achieved": bool, "fix_info": "..." (if not achieved),
  "test_output": "..." (optional)}
```

If `dod_achieved == false`: set `fix_info`, record step failed, go to Step 3.
Else `iteration.dod_achieved = true`. Save state.

#### Phase D — Code Quality

Set `current_phase: code_quality`. Invoke `execution-code-quality` agent.

Prompt template:

```
Analyze code quality for task: <task_id> (iteration <N>).

Files to analyze (changed this iteration):
<files_changed + files_added bullet list>

Run ruff, ty, complexipy on these files only. Filter false positives and
pre-existing issues. Only fail for genuine problems in the changed code.

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

#### Phase F — DoD Check

Set `current_phase: dod_check`. Invoke `execution-dod` agent.

Prompt template:

```
Verify if task is COMPLETE: <task_id> (iterations completed: <N>).
Task folder: <task_path>

Read user-stories/*.md and implementation-plan/phase-*.md directly.

Task is COMPLETE only if:
- ALL user stories have status 'Done'
- ALL acceptance criteria are checked [x]
- ALL implementation phases are complete

Return JSON: {"task_complete": bool, "remaining_items": [...], "reasoning": "..."}
```

If `task_complete == true`: set `current_phase: completed`, set
`completed_at: <now>`. Save state. **End the loop.**

If `task_complete == false`: record what's remaining, continue to next iteration
(go back to Step 2).

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
  [if completed]      DoD: ✓ Met
  [if failed/stopped] Reason: <error_message>
═══════════════════════════════════════════════
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
