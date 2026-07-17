---
description: Show Sahaidachny help and available commands
---

Output the following help information to the user:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                     SAHAIDACHNY COMMANDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SMALL TASKS (one command, in Claude Code):

  /saha:quick "<task>" Plan a small change in one pass, then /saha:execute

PLANNING COMMANDS — large tasks (in Claude Code):

  /saha:init <name>    Initialize new task folder (LikeC4 model + progress.yaml)
  /saha:research       Deep codebase exploration (research/*.md)
  /saha:task           Task description model (model/task.c4)
  /saha:stories        User stories as step-by-step flows (model/stories.c4)
  /saha:decide         Design decisions (model/decisions.c4)
  /saha:contracts      Code-change contracts (model/contracts.c4)
  /saha:test-specs     Test scenarios as flows (model/test-specs.c4)
  /saha:plan           Phased plan (model/phases.c4 + progress.yaml)
  /saha:verify         Compile + cross-reference the whole plan
  /saha:status         Check planning progress (reads progress.yaml)

  The plan is a LikeC4 model — review it visually in ghostling's Planning
  Mode (a static `likec4 build` of `<task>/model` — never `likec4 start`). All tracking lives in the
  task's progress.yaml; model/*.c4 freezes once execution starts.

EXECUTION COMMANDS (in Claude Code — subscription-billed):

  /saha:execute [task-id]     Run agentic loop in this session
  /saha:resume  [task-id]     Resume interrupted task in this session

EXECUTION COMMANDS (in terminal — uses API credits):

  saha use <task-id>          Set current task context
  saha use                    Show current task
  saha use --clear            Clear current task
  saha run [task-id]          Run agentic loop (API-billed, headless)
  saha resume [task-id]       Resume task (API-billed, headless)
  saha status [task-id]       Check execution status
  saha clean [task-id]        Clean execution state

WORKFLOW — small task (1-2 file change):

  1. /saha:quick "<one-line task>"   (one-pass plan, auto-sets current task)
  2. /saha:execute                   (subscription) — or `saha run` for API

WORKFLOW — large task:

  1. /saha:init my-feature       (auto-sets current task)
  2. /saha:task                   (define what we're building)
  3. /saha:research               (explore codebase with context)
  4. /saha:stories
  5. /saha:verify stories
  6. /saha:plan
  7. /saha:execute                (subscription) — or `saha run` for API

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
