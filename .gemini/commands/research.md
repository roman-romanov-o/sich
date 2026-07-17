---
description: Research codebase and validate assumptions for a task
argument-hint: [task-path] [--topic=<focus-area>]
allowed-tools: Task, Read, Edit, Glob, Grep, WebSearch, WebFetch, mcp__context7__resolve-library-id, mcp__context7__query-docs
---

# Research Task

Conduct critical codebase research for planning, using the task description as context.

## Arguments

- **task-path** (optional): Path to task folder (e.g., `docs/tasks/task-01-auth`)
  - If not provided, detects from current context or prompts
- `--topic=<focus-area>`: Specific area to investigate

## Prerequisites

Before running this command:
1. Task folder must exist (run `/saha:init` first)
2. Task model should exist (run `/saha:task` first)

The task model provides essential context for focused research. Research output
itself stays **markdown** (`research/*.md`) — it is prose, not spec.

## Execution

### 1. Detect Task Context

If no task path provided, resolve using this priority:
1. Read `.sahaidachny/current-task` for the active task ID, then find its folder in `docs/tasks/`
2. Fallback to the most recent task folder in `docs/tasks/`
3. If no task context found, ask the user which task to research for.

### 2. Launch Research Agent

Use the Task tool to launch the research subagent:

```
Task tool:
  subagent_type: general-purpose
  prompt: |
    You are the Sahaidachny Research Agent. Read your full instructions from:
    .claude/agents/planning_research.md

    Task context:
    - Task path: {task_path}
    - Task model: {task_path}/model/task.c4 (saha/v2) — or {task_path}/task-description.md on a legacy task
    - Task state: {task_path}/progress.yaml
    - Architecture model (if present): docs/architecture/*.c4 — read as context;
      flag drift between the model and the actual code as a research finding
    ${topic ? "- Focus topic: " + topic : ""}

    Research the codebase thoroughly. Be critical and skeptical.
    Write findings to: {task_path}/research/

    Start by reading the task description to understand what we're building and what needs to be researched.
```

### 3. Expected Outputs

The agent will create in `{task_path}/research/`:
- Research reports for each investigated topic
- Critical assessment of the proposed task

Then update `{task_path}/progress.yaml`:

```yaml
planning:
  research: { status: done, artifacts: [research/codebase-analysis.md, …] }
```

## After Research

Review the research findings. They may:
- Confirm the approach is sound
- Identify required adjustments
- Recommend reconsidering the task

Based on findings:
- If the task model needs updates, revise it with `/saha:task`
- Otherwise, proceed to `/saha:stories` to generate user stories

## 4. Review Artifacts

Launch the reviewer agent to validate research quality:

```
Task tool:
  subagent_type: general-purpose
  prompt: |
    You are the Sahaidachny Reviewer. Read your instructions from:
    .claude/agents/planning_reviewer.md

    Review mode: research
    Task path: {task_path}
    Artifacts to review: {task_path}/research/*.md

    Review the research artifacts and report any issues.
```

If the reviewer finds blockers (🔴), present them to the user before proceeding.
If only warnings (🟡), note them but allow proceeding.

## Example Usage

```
/saha:research docs/tasks/task-01-authentication
/saha:research --topic=database-migrations
```
