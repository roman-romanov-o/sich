---
description: Resume an interrupted saha execution loop from saved state
argument-hint: [task-id]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task
---

# Saha Resume

Resume a previously interrupted execution loop. Reads
`.sahaidachny/<task_id>-execution-state.yaml` and continues from the last
incomplete phase. All subagent calls run in this session (subscription-billed).

## Arguments

- **task-id** (optional, positional): which task to resume. If omitted, read
  from `.sahaidachny/current-task`. If that's missing too, ask the user.

## Execution recipe

### Step 1 — Load state

1. Resolve `task_id` (positional > `.sahaidachny/current-task` > ask user).
2. Read state file: `.sahaidachny/<task_id>-execution-state.yaml`.
   If missing: tell the user there's nothing to resume, suggest `/saha:execute <task_id>`, stop.
3. Parse the YAML. Validate `current_phase` is **not** in
   `{completed, completed_pending_manual, failed, stopped}` — if it is, tell the
   user the task already finished and exit. For `completed_pending_manual`, print the
   pending manual checklist from `state.context.pending_manual_checks` so they still
   see what needs human sign-off. Show `state.error_message` if present.
4. **Validate the task is saha/v2**: `state.task_path` must contain `progress.yaml`
   with `format: saha/v2`. If not, this state predates the v2 format — tell the user
   to re-run with the legacy path (`saha resume`) or re-plan, and stop.
5. **Ensure the toolchain is resolved**: if `state.context.stack` is missing (older
   state file), run Step 0 of `/saha:execute` to resolve and stash it before
   continuing. Likewise ensure `state.context.pending_manual_checks` exists (default `[]`).
6. **Ensure the spec fingerprint exists**: if `state.context.spec_fingerprint` is
   missing, compute it now (`cd <task_path> && shasum model/*.c4`) and stash it,
   noting in your output that spec-freeze integrity is only tracked from this
   resume point onward.

### Step 2 — Determine resume point

Look at the last iteration record:

- If the last iteration has `dod_achieved: true` and `quality_passed: true`
  and `current_phase` is `manager` or `dod_check` — pick up at the next
  unfinished phase of **that** iteration.
- Otherwise, the iteration was short-circuited. Pick up at the **next**
  iteration: increment `current_iteration`, append a new iteration record
  with `fix_info = state.context.fix_info`, then start Phase A.

If `current_iteration >= max_iterations`, stop with a clear message.

### Step 3 — Run remaining phases

Follow the same phase recipe as `/saha:execute` (see
`claude_plugin/commands/execute.md`, Step 2). Persist state after each phase.

The phase order — implementation → test_critique → qa → code_quality →
manager → dod_check — is the same. Use the same subagent invocations,
prompts, and JSON contracts.

When resuming **mid-iteration** (rare; only happens if interrupted between
phases of an otherwise-passing iteration), skip phases whose step records
already show `status: completed` and start at the next unfinished one.

### Step 4 — Termination

Same summary block as `/saha:execute`:

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

For `completed_pending_manual`, also print the manual checklist (same format as
`/saha:execute` Step 4).

## Notes

- Resume is most useful after a Ctrl-C or session crash. If the previous run
  failed in the implementer phase with a fatal error (e.g. tool error),
  resume will simply re-attempt with the same `fix_info`.
- The state file is the source of truth — don't try to reconstruct from
  task artifacts.
