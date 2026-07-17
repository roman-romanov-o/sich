---
description: Create or update the task description model
argument-hint: [task-path]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion, Task
---

# Task Description

Create the task description as a reviewable **LikeC4 context model** through
interactive refinement. The human reviews this as a diagram in ghostling — not as
prose — so the model, not a document, is the deliverable.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user

## Prerequisites

Before running this command:
1. Task folder must exist (run `/saha:init` first) — it contains `model/spec.c4`
   and `progress.yaml`

This is typically the first planning step after init. The task description provides context for subsequent research.

## Execution

### 1. Gather Context

Read existing materials:
- `{task_path}/progress.yaml` - Task identity + planning state
- `{task_path}/research/*.md` - Research findings (if research was already done)
- `.claude/templates/task.c4` - The template/conventions for this artifact

### 2. Interactive Task Definition

Ask the user to clarify key aspects. Use AskUserQuestion for structured input.

**Required Information:**

1. **Problem Statement**: What problem does this solve?
2. **Success Criteria**: How do we know when it's done?
3. **Scope**: What's in scope? What's explicitly out of scope?
4. **Constraints**: Technical, time, or resource constraints?
5. **Dependencies**: What must exist before this can be built?

### 3. Generate the Task Model

Create `{task_path}/model/task.c4` following `.claude/templates/task.c4`:

- Model the **actors** (who uses/benefits), the **system container**, and the
  components this task touches — tag each `#existing` or `#new` so the reviewer
  sees the delta at a glance. Add `external` elements for dependencies.
- Prose goes where the reviewer will read it:
  - `description '''…'''` on the container: the 1-paragraph overview
  - `metadata { goals / non_goals / constraints }`: structured facts
  - Success criteria summary: the `task-context` view `description`
- Relations state HOW new integrates with existing (`user -> sys.x '…'`,
  `sys.new -> sys.old '…'`).
- The overview view **must be named `task-context`** — progress.yaml and the
  kanban app point at it.

Element ids introduced here (`sys`, its components, actors) are the shared
vocabulary every later artifact (`stories.c4`, `contracts.c4`, …) references.
Choose short, stable, snake_case ids — but NEVER a LikeC4 property keyword
(`summary`, `title`, `description`, `technology`, `link`, `icon`, `style`,
`metadata`, `navigateTo`): `validate` rejects it with a cryptic
`Expecting token '}'` error. A `--summary` feature's component is
`repo_summary`, not `summary`.

### 4. Incorporate Research (if available)

If research documents already exist in `research/`:
- Model the affected components research identified (with `metadata { files '…' }`)
- Reflect validated/invalidated assumptions in descriptions
- Note risks in `metadata`

### 5. Compile Gate

The model must compile before review:

```bash
likec4 validate {task_path}/model
```

Fix any errors. If the `likec4` CLI is missing, tell the user
(`npm i -g likec4`) and continue — authoring is still valid, rendering degrades.

### 6. Validate with User

After generating, ask:
- Does this accurately capture the task?
- Are success criteria measurable and complete?
- Is the scope clear?

Iterate until the user approves. Remind them they can review visually in
ghostling's Planning Mode (a static `likec4 build` of `{task_path}/model` — never `likec4 start`).

### 7. Update progress.yaml

Update `{task_path}/progress.yaml` (the ONLY file that tracks status):

```yaml
planning:
  task_description: { status: in_progress, views: [task-context] }
```

Keep `in_progress` here — `done` is written only in step 8, after the review
passes and the user approves.

## 8. Review Artifacts

Launch the reviewer agent to validate the task model:

```
Task tool:
  subagent_type: general-purpose
  prompt: |
    You are the Sahaidachny Reviewer. Read your instructions from:
    .claude/agents/planning_reviewer.md

    Review mode: task
    Task path: {task_path}
    Artifacts to review: {task_path}/model/task.c4

    Review the task description model and report any issues.
```

If the reviewer finds blockers (🔴), work with user to fix before proceeding.
When the review passes and the user approves, set
`planning.task_description.status: done` in progress.yaml.

## Example Usage

```
/saha:task docs/tasks/task-01-auth
```

## Output

Creates or updates:
- `{task_path}/model/task.c4` (view `task-context`)
- `{task_path}/progress.yaml` (planning.task_description)
