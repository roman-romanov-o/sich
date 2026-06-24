---
description: Generate user stories from task description
argument-hint: [task-path] [--count=N]
allowed-tools: Read, Write, Glob, AskUserQuestion, Task
---

# User Stories

Generate user stories from the task description.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user
- `--count=N`: Number of stories to generate initially (default: auto-detect based on scope)

## Prerequisites

Task description must exist. Check for `{task_path}/task-description.md`.
If missing, suggest running `/saha:task` first.

## Execution

### 1. Analyze Task

Read and understand:
- `{task_path}/task-description.md` - Core requirements
- `{task_path}/research/*.md` - Technical context

### 2. Identify User Personas

From the task description, identify who will use this feature:
- End users
- Administrators
- Developers (if internal tooling)
- System actors (automated processes)

### 3. Generate Story Candidates

For each persona and scope item, draft user stories.

**Story Format:**
```
As a [persona],
I want to [action],
So that [benefit].
```

### 4. Prioritize with User

Present story candidates and ask user to:
1. Confirm/reject each story
2. Adjust priority (Must Have / Should Have / Could Have / Won't Have)
3. Add missing stories

### 5. Create Story Files

For each approved story, create `{task_path}/user-stories/US-XXX-{slug}.md`:

```markdown
# US-XXX: [Short Title]

**Priority:** Must Have | Should Have | Could Have
**Status:** Draft | Ready | Approved
**Persona:** [User type]
**Estimated Complexity:** S | M | L | XL

## User Story

As a **[persona]**,
I want to **[action]**,
So that **[benefit]**.

## Acceptance Criteria

Conditions that must be true for this story to be complete:

1. **Given** [initial context]
   **When** [action is taken]
   **Then** [expected outcome]

2. **Given** [context]
   **When** [action]
   **Then** [outcome]

## Edge Cases

Scenarios that need explicit handling:

1. **[Edge case name]**
   - Trigger: [What causes this]
   - Expected behavior: [What should happen]

2. **[Edge case name]**
   - Trigger: [...]
   - Expected behavior: [...]

## Technical Notes

[Any technical considerations from research]

## Dependencies

- **Requires:** [Other stories this depends on]
- **Enables:** [Stories that depend on this]

## Questions

- [ ] [Open question to resolve]

## Related

- Task: [Link to task-description.md]
- Research: [Link to relevant research]
- Design Decision: [DD-XXX if applicable]
```

### 6. Update User Stories README

Update `{task_path}/user-stories/README.md`:

```markdown
# User Stories

User stories define features from the user's perspective.

## Contents

| ID | Title | Priority | Status |
|----|-------|----------|--------|
| US-001 | [Title] | Must Have | Draft |
| US-002 | [Title] | Should Have | Draft |

## Story Map

[Visual grouping by persona or feature area]

### [Persona 1]
- US-001: [Title]
- US-002: [Title]

### [Persona 2]
- US-003: [Title]
```

### 7. Update Task README

Update `{task_path}/README.md` progress table:
- Set "User Stories" row to status based on count

## Story Writing Guidelines

**Good stories are:**
- Independent (can be developed separately)
- Negotiable (details can be discussed)
- Valuable (delivers user/business value)
- Estimable (can estimate complexity)
- Small (fits in one iteration)
- Testable (has clear acceptance criteria)

**Avoid:**
- Technical implementation details in the story itself
- Compound stories (multiple features in one)
- Stories without clear acceptance criteria
- Stories that can't be demonstrated

## 8. Review Artifacts

Launch the reviewer agent to validate user stories:

```
Task tool:
  subagent_type: general-purpose
  prompt: |
    You are the Sahaidachny Reviewer. Read your instructions from:
    .claude/agents/planning_reviewer.md

    Review mode: stories
    Task path: {task_path}
    Artifacts to review: {task_path}/user-stories/US-*.md

    Review the user stories and report any issues.
```

If the reviewer finds blockers (🔴), fix before proceeding.

## Example Usage

```
/saha:stories docs/tasks/task-01-auth
/saha:stories --count=5
```

## Output

Creates:
- `{task_path}/user-stories/US-XXX-{slug}.md` (one per story)
- Updates `{task_path}/user-stories/README.md`
- Updates `{task_path}/README.md`
