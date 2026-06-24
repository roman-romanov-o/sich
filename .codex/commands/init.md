---
description: Initialize a new Sahaidachny task folder structure
argument-hint: <task-name> [--mode=full|minimal] [--path=docs/tasks]
allowed-tools: Bash
---

# Initialize Sahaidachny Task

Create a new hierarchical task structure for planning.

## Arguments

- First argument: **Task name** (required) - Short descriptive name
- `--mode=full|minimal`: Planning mode (default: full)
- `--path=<path>`: Base path for tasks (default: docs/tasks)

## Execution

Run the init script:

```bash
bash .claude/scripts/init_task.sh $ARGUMENTS
```

This creates:

```
{base_path}/task-XX-{name}/
├── README.md                    # Task dashboard
├── user-stories/README.md
├── design-decisions/README.md
├── code-changes/README.md
├── implementation-plan/README.md
├── test-specs/
│   ├── README.md
│   ├── e2e/README.md
│   ├── integration/README.md
│   └── unit/README.md
└── research/README.md
```

## Example Usage

```
/saha:init user-authentication
/saha:init payment-integration --mode=minimal
/saha:init api-refactor --path=planning/tasks
```

The init script automatically sets the new task as the current task context
(`.sahaidachny/current-task`), so all subsequent commands will use it without
needing to specify the task path.

After initialization, follow the suggested next step shown in output.
