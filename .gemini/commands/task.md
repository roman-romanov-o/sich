---
description: Create or update the task description document
argument-hint: [task-path]
allowed-tools: Read, Write, Glob, Grep, AskUserQuestion, Task
---

# Task Description

Create a comprehensive task description document through interactive refinement.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user

## Prerequisites

Before running this command:
1. Task folder must exist (run `/saha:init` first)

This is typically the first planning step after init. The task description provides context for subsequent research.

## Execution

### 1. Gather Context

Read existing materials:
- `{task_path}/README.md` - Task overview
- `{task_path}/research/*.md` - Research findings (if research was already done)

### 2. Interactive Task Definition

Ask the user to clarify key aspects. Use AskUserQuestion for structured input.

**Required Information:**

1. **Problem Statement**: What problem does this solve?
2. **Success Criteria**: How do we know when it's done?
3. **Scope**: What's in scope? What's explicitly out of scope?
4. **Constraints**: Technical, time, or resource constraints?
5. **Dependencies**: What must exist before this can be built?

### 3. Generate Task Description

Create `{task_path}/task-description.md`:

```markdown
# Task Description: [Title]

**Task ID:** TASK-XX
**Status:** Draft | Ready for Stories | Approved
**Last Updated:** YYYY-MM-DD

## Problem Statement

[Clear description of the problem being solved]

### Current State

[How things work now / what's broken / what's missing]

### Desired State

[What we want to achieve]

## Success Criteria

Measurable outcomes that define "done":

1. [ ] [Specific, measurable criterion]
2. [ ] [Another criterion]
3. [ ] [...]

## Scope

### In Scope

- [Feature/change that IS included]
- [...]

### Out of Scope

- [Feature/change that is NOT included]
- [...]

## Constraints

| Type | Constraint | Reason |
|------|------------|--------|
| Technical | [e.g., Must use existing auth system] | [Why] |
| Time | [e.g., Must ship before Q2] | [Why] |
| Resource | [e.g., No new dependencies] | [Why] |

## Dependencies

### Prerequisites

- [ ] [What must exist before we start]

### Blockers

- [ ] [Known blockers to resolve]

## Technical Context

[Relevant technical details from research]

### Affected Components

- `path/to/component` - [How it's affected]

### Integration Points

- [System/service that needs integration]

## Open Questions

- [ ] [Unresolved question that needs answering]

## References

- [Link to research documents]
- [Link to related documentation]
```

### 4. Incorporate Research (if available)

If research documents already exist in `research/`:
- Pull key findings into Technical Context
- Reference research files
- Include validated/invalidated assumptions
- Add identified risks

Note: Research typically runs after task description. The Technical Context section can be updated later when research completes.

### 5. Validate with User

After generating, ask:
- Does this accurately capture the task?
- Are success criteria measurable and complete?
- Is the scope clear?

Iterate until the user approves.

### 6. Update README

Update `{task_path}/README.md` progress table:
- Set "Task Description" row to "Complete" or "In Progress"

## 7. Review Artifacts

Launch the reviewer agent to validate task description:

```
Task tool:
  subagent_type: general-purpose
  prompt: |
    You are the Sahaidachny Reviewer. Read your instructions from:
    .claude/agents/planning_reviewer.md

    Review mode: task
    Task path: {task_path}
    Artifacts to review: {task_path}/task-description.md

    Review the task description and report any issues.
```

If the reviewer finds blockers (🔴), work with user to fix before proceeding.

## Example Usage

```
/saha:task docs/tasks/task-01-auth
```

## Output

Creates or updates:
- `{task_path}/task-description.md`
- `{task_path}/README.md` (progress update)
