#!/bin/bash
#
# Initialize a new Sahaidachny task folder (format saha/v2: LikeC4 model + progress.yaml)
#
# Usage:
#   ./init_task.sh <task-name> [--path=docs/tasks]
#
# Example:
#   ./init_task.sh user-authentication
#   ./init_task.sh api-refactor --path=planning/tasks

set -e

# Get script directory (where templates live)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"

# Defaults
BASE_PATH="docs/tasks"
TASK_NAME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --path=*)
            BASE_PATH="${1#*=}"
            shift
            ;;
        -*)
            echo "Error: Unknown option $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$TASK_NAME" ]]; then
                TASK_NAME="$1"
            fi
            shift
            ;;
    esac
done

# Validate task name
if [[ -z "$TASK_NAME" ]]; then
    echo "Error: Task name is required" >&2
    echo "Usage: $0 <task-name> [--path=docs/tasks]" >&2
    exit 1
fi

# Slugify task name (portable)
SLUG=$(echo "$TASK_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[ _]/-/g' | sed 's/[^a-z0-9-]//g' | sed 's/-\{2,\}/-/g' | sed 's/^-//;s/-$//')

# Create base path if needed
mkdir -p "$BASE_PATH"

# Find next task number
NEXT_NUM=1
if [[ -d "$BASE_PATH" ]]; then
    for dir in "$BASE_PATH"/task-*/; do
        if [[ -d "$dir" ]]; then
            NUM=$(basename "$dir" | sed 's/task-\([0-9]*\).*/\1/' | sed 's/^0*//')
            if echo "$NUM" | grep -qE '^[0-9]+$' && [[ "$NUM" -ge "$NEXT_NUM" ]]; then
                NEXT_NUM=$((NUM + 1))
            fi
        fi
    done
fi

# Format task ID
TASK_ID=$(printf "task-%02d" "$NEXT_NUM")
TASK_ID_UPPER=$(echo "$TASK_ID" | tr '[:lower:]' '[:upper:]')
FOLDER_NAME="${TASK_ID}-${SLUG}"
TASK_PATH="${BASE_PATH}/${FOLDER_NAME}"

# Check if already exists
if [[ -d "$TASK_PATH" ]]; then
    echo "Error: Task folder already exists: $TASK_PATH" >&2
    exit 1
fi

# Create title from name (capitalize words)
TITLE=$(echo "$TASK_NAME" | sed 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')

# Get today's date
TODAY=$(date +%Y-%m-%d)

# Create folder structure: model/ holds the LikeC4 spec, research/ holds prose.
mkdir -p "$TASK_PATH/model"
mkdir -p "$TASK_PATH/research"

# spec.c4 is placeholder-free — install it verbatim so `likec4 build model/`
# is green from the very first commit.
if [[ -f "$TEMPLATE_DIR/spec.c4" ]]; then
    cp "$TEMPLATE_DIR/spec.c4" "$TASK_PATH/model/spec.c4"
fi

# Research prose template (research stays markdown).
if [[ -f "$TEMPLATE_DIR/research-report.md" ]]; then
    cp "$TEMPLATE_DIR/research-report.md" "$TASK_PATH/research/_TEMPLATE_research-report.md"
fi

# progress.yaml — THE single mutable tracking file (see templates/progress.yaml for
# the full documented schema). Starts minimal: all planning steps pending.
cat > "$TASK_PATH/progress.yaml" << PROGEOF
format: saha/v2
task: "${FOLDER_NAME}"
title: "${TITLE}"
created: "${TODAY}"
mode: full
status: planning

planning:
  research:            { status: pending, artifacts: [] }
  task_description:    { status: pending, views: [] }
  user_stories:        { status: pending, views: [] }
  design_decisions:    { status: pending, views: [] }
  code_changes:        { status: pending, views: [] }
  test_specs:          { status: pending, views: [] }
  implementation_plan: { status: pending, views: [] }
  verify:              { status: pending }

stories: []
phases: []
iterations: []
PROGEOF

# Human pointer only — ALL state lives in progress.yaml, the spec in model/*.c4.
cat > "$TASK_PATH/README.md" << MAINEOF
# ${TASK_ID_UPPER}: ${TITLE}

Saha v2 task — the plan is a LikeC4 model, tracking is machine-readable.

- **Review the plan:** open this task in ghostling (Planning Mode), which renders a static \`likec4 build\` of \`model/\`
- **State:** \`progress.yaml\` (single source of truth — do not track status anywhere else)
- **Spec:** \`model/*.c4\` (frozen once execution starts)
MAINEOF

# Set as current task context
mkdir -p ".sahaidachny" && echo "${FOLDER_NAME}" > ".sahaidachny/current-task"

# Output
echo "Created task folder: ${TASK_PATH}"
echo "Task ID: ${TASK_ID}"
echo "Current task set to: ${FOLDER_NAME}"
echo ""
echo "Next step: /saha:research"
