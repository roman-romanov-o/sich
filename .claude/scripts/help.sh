#!/bin/bash
# Sahaidachny help - outputs directly without Claude processing

cat << 'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                     SAHAIDACHNY COMMANDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SMALL TASKS (one command, in Claude Code):

  /saha:quick "<task>" Plan a small change in one pass, then /saha:execute

PLANNING COMMANDS — large tasks (in Claude Code):

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

  saha run <task-id>          Run agentic execution loop
  saha resume <task-id>       Resume interrupted task
  saha status [task-id]       Check execution status
  saha clean [task-id]        Clean execution state

WORKFLOW — small task:

  1. /saha:quick "add a --json flag to status output"
  2. saha run <task-id>        (or /saha:execute in Claude Code)

WORKFLOW — large task:

  1. /saha:init my-feature
  2. /saha:research
  3. /saha:task
  4. /saha:stories
  5. /saha:verify stories
  6. /saha:plan
  7. saha run <task-id>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

exit 0
