---
description: Show Sahaidachny help and available commands
---

Output the following help information to the user:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                     SAHAIDACHNY COMMANDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PLANNING COMMANDS (in Claude Code):

  /saha:init <name>    Initialize new task folder
  /saha:research       Deep codebase exploration
  /saha:task           Define task description
  /saha:stories        Generate user stories
  /saha:decide         Document decision points
  /saha:contracts      Define code changes
  /saha:test-specs     Create test specifications
  /saha:verify <item>  Verify planning artifacts
  /saha:plan           Generate execution plan
  /saha:status         Check planning progress

EXECUTION COMMANDS (in terminal):

  saha use <task-id>          Set current task context
  saha use                    Show current task
  saha use --clear            Clear current task
  saha run [task-id]          Run agentic execution loop
  saha resume [task-id]       Resume interrupted task
  saha status [task-id]       Check execution status
  saha clean [task-id]        Clean execution state

WORKFLOW:

  1. /saha:init my-feature       (auto-sets current task)
  2. /saha:task                   (define what we're building)
  3. /saha:research               (explore codebase with context)
  4. /saha:stories
  5. /saha:verify stories
  6. /saha:plan
  7. saha run                     (uses current task)

MODES:

  --mode=full      Complete planning (all artifacts)
  --mode=minimal   Lightweight (task + plan only)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
