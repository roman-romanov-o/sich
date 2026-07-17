---
description: Show planning progress dashboard for a task
argument-hint: [task-path]
allowed-tools: Read, Glob, Bash
---

# Task Status Dashboard

Display the current planning progress for a Sahaidachny task.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detect from `docs/tasks/` (most recent)

## Execution

### 1. Find Task

If no path provided, resolve using this priority:
1. Read `.sahaidachny/current-task` for the active task ID, then find its folder in `docs/tasks/`
2. Fallback to the most recent task folder: `ls -td docs/tasks/task-*/ 2>/dev/null | head -1`
3. If no tasks exist, inform user to run `/saha:init` first.

### 2. Read State

**saha/v2 task** (has `progress.yaml` with `format: saha/v2`): the dashboard is
a straight read of that file — `planning.*` statuses, story/AC counts and
statuses, phase progress, iteration count. Do not scan or scrape anything else.

**Legacy task** (no progress.yaml): fall back to counting markdown artifacts
per the old layout (`user-stories/US-*.md`, `implementation-plan/phase-*.md`, …)
and note the task predates saha/v2.

### 3. Display Dashboard

```
╔══════════════════════════════════════════════════════════╗
║  TASK-XX: [Title]                        (saha/v2)       ║
║  Created: YYYY-MM-DD   Status: planning                  ║
╠══════════════════════════════════════════════════════════╣
║  Planning Progress                                       ║
╠══════════════════════════════════════════════════════════╣
║  [●] Research              1 report      ✅ Done         ║
║  [●] Task Description      task-context  ✅ Done         ║
║  [◐] User Stories          2 views       🔄 In Progress  ║
║  [○] Design Decisions      —             ⏳ Pending      ║
║  [○] Code Changes          —             ⏳ Pending      ║
║  [○] Test Specs            —             ⏳ Pending      ║
║  [○] Implementation Plan   —             ⏳ Pending      ║
║  [○] Verify                —             ⏳ Pending      ║
╠══════════════════════════════════════════════════════════╣
║  Stories: 2 (2 draft)   ACs: 5 (5 pending)               ║
║  Phases:  —             Iterations: 0                    ║
╠══════════════════════════════════════════════════════════╣
║  Next Step: /saha:decide                                 ║
╚══════════════════════════════════════════════════════════╝
```

During/after execution (`status: executing` or beyond), also show per-phase
step progress and per-story AC ticks from the same file, plus any
`completed_pending_manual` ACs awaiting human sign-off.

### 4. Suggest Next Step

Based on workflow order — the first `planning.*` entry that isn't `done`/`skipped`:
1. Research → `/saha:research`
2. Task Description → `/saha:task`
3. User Stories → `/saha:stories`
4. Design Decisions → `/saha:decide` (full mode only)
5. Code Changes → `/saha:contracts` (full mode only)
6. Test Specs → `/saha:test-specs`
7. Implementation Plan → `/saha:plan`
8. Verify → `/saha:verify`
9. All done → `/saha:execute`

Remind the user the plan is reviewable visually in ghostling's Planning Mode
(it renders a static `likec4 build` of `{task_path}/model` — never `likec4 start`).

## Example Output

```
/saha:status docs/tasks/task-01-auth
```
