---
description: Initialize a new Sahaidachny task folder structure
argument-hint: <task-name> [--path=docs/tasks]
allowed-tools: Bash
---

# Initialize Sahaidachny Task

Create a new task in **saha/v2 format**: the plan is authored as a LikeC4 model the
human reviews visually; all tracking lives in one machine-readable `progress.yaml`.

> For a **small** change (1-2 files), use `/saha:quick "<one-line task>"` instead —
> it plans in one pass and hands straight off to `/saha:execute`.

## Arguments

- First argument: **Task name** (required) - Short descriptive name
- `--path=<path>`: Base path for tasks (default: docs/tasks)

## Execution

Run the init script:

```bash
bash .claude/scripts/init_task.sh $ARGUMENTS
```

This creates:

```
{base_path}/task-XX-{name}/
├── README.md            # 5-line human pointer (no state here)
├── progress.yaml        # THE tracking file (format: saha/v2)
├── model/
│   └── spec.c4          # shared LikeC4 element kinds/tags for this task
└── research/            # research prose stays markdown
```

Planning commands then grow the model:

| Step | Command | Writes |
|------|---------|--------|
| Research | `/saha:research` | `research/*.md` |
| Task Description | `/saha:task` | `model/task.c4` (view `task-context`) |
| User Stories | `/saha:stories` | `model/stories.c4` (dynamic views `us-NNN-flow`) + `progress.yaml` stories |
| Design Decisions | `/saha:decide` | `model/decisions.c4` (view `decisions`) |
| Code Changes | `/saha:contracts` | `model/contracts.c4` (view `contracts`) |
| Test Specs | `/saha:test-specs` | `model/test-specs.c4` (views `ts-*`) |
| Implementation Plan | `/saha:plan` | `model/phases.c4` (view `phases`) + `progress.yaml` phases |
| Verify | `/saha:verify` | validation only |

**The two-file rule:** `model/*.c4` is the frozen spec (never edited after execution
starts); `progress.yaml` is the only file any status update ever touches.

## Example Usage

```
/saha:init user-authentication
/saha:init api-refactor --path=planning/tasks
```

The init script automatically sets the new task as the current task context
(`.sahaidachny/current-task`), so all subsequent commands will use it without
needing to specify the task path.

After initialization, follow the suggested next step shown in output.

## Toolchain (language-agnostic)

Saha is **not** Python-specific. The execution loop auto-detects the project's
build/test/quality commands from marker files at the repo root (`pyproject.toml`,
`Package.swift`, `package.json`, `Cargo.toml`, `go.mod`). To pin or override them —
or to tell the loop a target has **no** headless tests — create an optional
`.sahaidachny/stack.yaml`:

```yaml
# .sahaidachny/stack.yaml — overrides auto-detection
build:   { command: "swift build" }
test:    { command: "swift test", file_globs: ["**/*Tests.swift"] }
quality: { commands: ["swiftlint"], changed_files_only: true }
run:     { command: "swift run" }
# An empty command (e.g. test.command: "") tells the loop to SKIP that gate —
# use this for a UI-only target whose ACs are all verify:build / verify:manual.
```

Rendering the model needs the LikeC4 CLI (`npm i -g likec4`); without it the plan
is still reviewable as source, and ghostling degrades gracefully.
