#!/bin/bash
#
# Initialize a new Sahaidachny task folder structure
#
# Usage:
#   ./init_task.sh <task-name> [--mode=full|minimal] [--path=docs/tasks]
#
# Example:
#   ./init_task.sh user-authentication
#   ./init_task.sh payment-flow --mode=minimal
#   ./init_task.sh api-refactor --path=planning/tasks

set -e

# Get script directory (where templates live)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"

# Defaults
MODE="full"
BASE_PATH="docs/tasks"
TASK_NAME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --mode=*)
            MODE="${1#*=}"
            shift
            ;;
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
    echo "Usage: $0 <task-name> [--mode=full|minimal] [--path=docs/tasks]" >&2
    exit 1
fi

# Validate mode
if [[ "$MODE" != "full" && "$MODE" != "minimal" ]]; then
    echo "Error: Mode must be 'full' or 'minimal'" >&2
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

# Capitalize mode for display
MODE_DISPLAY=$(echo "$MODE" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')

# Get today's date
TODAY=$(date +%Y-%m-%d)

# Create folder structure based on mode
mkdir -p "$TASK_PATH"
mkdir -p "$TASK_PATH/user-stories"
mkdir -p "$TASK_PATH/implementation-plan"
mkdir -p "$TASK_PATH/test-specs/e2e"
mkdir -p "$TASK_PATH/test-specs/integration"
mkdir -p "$TASK_PATH/test-specs/unit"
mkdir -p "$TASK_PATH/research"

# Full mode only: design decisions and code changes
if [[ "$MODE" == "full" ]]; then
    mkdir -p "$TASK_PATH/design-decisions"
    mkdir -p "$TASK_PATH/code-changes"
fi

# Create main README based on mode
if [[ "$MODE" == "minimal" ]]; then
    cat > "$TASK_PATH/README.md" << MAINEOF
# ${TASK_ID_UPPER}: ${TITLE}

**Status:** Planning
**Mode:** ${MODE_DISPLAY}
**Created:** ${TODAY}

## Overview

[TODO: Add 1-2 sentence summary of the task]

## Planning Progress

| Step | Status | Artifacts |
|------|--------|-----------|
| Research | Pending | research/*.md |
| Task Description | Pending | task-description.md |
| User Stories | Pending | user-stories/US-*.md |
| Test Specs | Pending | test-specs/**/*.md |
| Implementation Plan | Pending | implementation-plan/phase-*.md |

## Next Steps

- [ ] Run \`/saha:research\` to explore the codebase
- [ ] Run \`/saha:task\` to create task description
MAINEOF
else
    cat > "$TASK_PATH/README.md" << MAINEOF
# ${TASK_ID_UPPER}: ${TITLE}

**Status:** Planning
**Mode:** ${MODE_DISPLAY}
**Created:** ${TODAY}

## Overview

[TODO: Add 1-2 sentence summary of the task]

## Planning Progress

| Step | Status | Artifacts |
|------|--------|-----------|
| Research | Pending | research/*.md |
| Task Description | Pending | task-description.md |
| User Stories | Pending | user-stories/US-*.md |
| Design Decisions | Pending | design-decisions/DD-*.md |
| Code Changes | Pending | code-changes/*.md |
| Test Specs | Pending | test-specs/**/*.md |
| Implementation Plan | Pending | implementation-plan/phase-*.md |

## Next Steps

- [ ] Run \`/saha:research\` to explore the codebase
- [ ] Run \`/saha:task\` to create task description
MAINEOF
fi

# Create subdirectory READMEs (common to both modes)
cat > "$TASK_PATH/user-stories/README.md" << 'EOF'
# User Stories

User stories define features from the user's perspective.

## Contents

_No artifacts yet._
EOF

cat > "$TASK_PATH/implementation-plan/README.md" << 'EOF'
# Implementation Plan

Phased execution plan with steps and dependencies.

## Contents

_No artifacts yet._
EOF

cat > "$TASK_PATH/research/README.md" << 'EOF'
# Research

Technical research and codebase analysis.

## Contents

_No artifacts yet._
EOF

cat > "$TASK_PATH/test-specs/README.md" << 'EOF'
# Test Specifications

Test specs organized by type.

## Contents

_No artifacts yet._
EOF

cat > "$TASK_PATH/test-specs/e2e/README.md" << 'EOF'
# End-to-End Tests

E2E test specifications.

## Contents

_No artifacts yet._
EOF

cat > "$TASK_PATH/test-specs/integration/README.md" << 'EOF'
# Integration Tests

Integration test specifications.

## Contents

_No artifacts yet._
EOF

cat > "$TASK_PATH/test-specs/unit/README.md" << 'EOF'
# Unit Tests

Unit test specifications.

## Contents

_No artifacts yet._
EOF

# Full mode only READMEs
if [[ "$MODE" == "full" ]]; then
    cat > "$TASK_PATH/design-decisions/README.md" << 'EOF'
# Design Decisions

Architectural decisions and their rationale.

## Contents

_No artifacts yet._
EOF

    cat > "$TASK_PATH/code-changes/README.md" << 'EOF'
# Code Changes

Interface definitions and API specifications.

## Contents

_No artifacts yet._
EOF
fi

# Copy templates (if template directory exists)
if [[ -d "$TEMPLATE_DIR" ]]; then
    # Common templates (both modes)
    [[ -f "$TEMPLATE_DIR/task-description.md" ]] && cp "$TEMPLATE_DIR/task-description.md" "$TASK_PATH/_TEMPLATE_task-description.md"
    [[ -f "$TEMPLATE_DIR/user-story.md" ]] && cp "$TEMPLATE_DIR/user-story.md" "$TASK_PATH/user-stories/_TEMPLATE_user-story.md"
    [[ -f "$TEMPLATE_DIR/research-report.md" ]] && cp "$TEMPLATE_DIR/research-report.md" "$TASK_PATH/research/_TEMPLATE_research-report.md"
    [[ -f "$TEMPLATE_DIR/implementation-phase.md" ]] && cp "$TEMPLATE_DIR/implementation-phase.md" "$TASK_PATH/implementation-plan/_TEMPLATE_phase.md"
    [[ -f "$TEMPLATE_DIR/test-spec-e2e.md" ]] && cp "$TEMPLATE_DIR/test-spec-e2e.md" "$TASK_PATH/test-specs/e2e/_TEMPLATE_test-spec.md"
    [[ -f "$TEMPLATE_DIR/test-spec-integration.md" ]] && cp "$TEMPLATE_DIR/test-spec-integration.md" "$TASK_PATH/test-specs/integration/_TEMPLATE_test-spec.md"
    [[ -f "$TEMPLATE_DIR/test-spec-unit.md" ]] && cp "$TEMPLATE_DIR/test-spec-unit.md" "$TASK_PATH/test-specs/unit/_TEMPLATE_test-spec.md"

    # Full mode only templates
    if [[ "$MODE" == "full" ]]; then
        [[ -f "$TEMPLATE_DIR/design-decision.md" ]] && cp "$TEMPLATE_DIR/design-decision.md" "$TASK_PATH/design-decisions/_TEMPLATE_design-decision.md"
        [[ -f "$TEMPLATE_DIR/code-change-rest.md" ]] && cp "$TEMPLATE_DIR/code-change-rest.md" "$TASK_PATH/code-changes/_TEMPLATE_code-change-rest.md"
        [[ -f "$TEMPLATE_DIR/code-change-event.md" ]] && cp "$TEMPLATE_DIR/code-change-event.md" "$TASK_PATH/code-changes/_TEMPLATE_code-change-event.md"
    fi
fi

# Set as current task context
mkdir -p ".sahaidachny" && echo "${FOLDER_NAME}" > ".sahaidachny/current-task"

# Output
echo "Created task folder: ${TASK_PATH}"
echo "Task ID: ${TASK_ID}"
echo "Mode: ${MODE}"
echo "Current task set to: ${FOLDER_NAME}"
echo ""
echo "Next step: /saha:research"
