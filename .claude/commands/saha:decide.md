---
description: Document architectural and design decisions
argument-hint: [task-path] [--title=<decision-title>]
allowed-tools: Read, Write, Glob, Grep, AskUserQuestion, WebSearch, Task, mcp__context7__resolve-library-id, mcp__context7__query-docs
---

# Design Decisions

Document architectural decisions and their rationale (ADR format).

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user
- `--title=<title>`: Create a specific decision document

## Prerequisites

- Task folder must exist
- User stories should be defined (for context)
- Only available in **full mode** (check README.md for mode)

Check mode in `{task_path}/README.md`. If minimal mode, inform user this step is skipped.

## Execution

### 1. Identify Decision Points

Review existing artifacts for decisions that need documenting:
- `{task_path}/task-description.md` - Constraints and technical context
- `{task_path}/user-stories/*.md` - Technical notes and questions
- `{task_path}/research/*.md` - Identified risks and recommendations

Look for:
- Technology choices (libraries, frameworks, services)
- Architectural patterns (how components interact)
- Data model decisions (schema, storage)
- API design choices
- Security approaches
- Performance trade-offs

### 2. Present Decision Candidates

List potential decisions and ask user which to document:

Example candidates:
- DD-001: Authentication mechanism (JWT vs Session)
- DD-002: Database choice (PostgreSQL vs MongoDB)
- DD-003: API versioning strategy

### 3. Document Each Decision

For each decision, gather through conversation:

1. **Context**: Why is this decision needed?
2. **Options**: What alternatives were considered?
3. **Decision**: What was chosen and why?
4. **Consequences**: What are the trade-offs?

Use Context7 and WebSearch to research options if needed.

### 4. Create Decision Files

Create `{task_path}/design-decisions/DD-XXX-{slug}.md`:

```markdown
# DD-XXX: [Decision Title]

**Status:** Proposed | Accepted | Deprecated | Superseded
**Date:** YYYY-MM-DD
**Deciders:** [Who made this decision]

## Context

[Why is this decision necessary? What problem are we solving?]

### Constraints

- [Constraint that affects this decision]
- [Another constraint]

### Requirements

- [Requirement this decision must satisfy]

## Options Considered

### Option 1: [Name]

**Description:** [How this option works]

**Pros:**
- [Advantage]
- [Another advantage]

**Cons:**
- [Disadvantage]
- [Another disadvantage]

**Effort:** Low | Medium | High

### Option 2: [Name]

**Description:** [...]

**Pros:**
- [...]

**Cons:**
- [...]

**Effort:** [...]

### Option 3: [Name]

[...]

## Decision

**Chosen Option:** [Option N - Name]

### Rationale

[Why this option was selected over others]

### Key Factors

1. [Most important factor in the decision]
2. [Second factor]
3. [...]

## Consequences

### Positive

- [Good outcome of this decision]
- [Another benefit]

### Negative

- [Trade-off we're accepting]
- [Technical debt or limitation]

### Neutral

- [Change that's neither good nor bad]

## Implementation Notes

[Guidance for implementing this decision]

```
[Code example if helpful]
```

## Related

- **Task:** [Link to task-description.md]
- **Stories:** [US-XXX, US-YYY that this affects]
- **Supersedes:** [DD-XXX if replacing another decision]
- **Related Decisions:** [DD-XXX other related decisions]

## References

- [External documentation]
- [Research that informed this]
```

### 5. Update Design Decisions README

Update `{task_path}/design-decisions/README.md`:

```markdown
# Design Decisions

Architectural decisions and their rationale.

## Contents

| ID | Title | Status | Date |
|----|-------|--------|------|
| DD-001 | [Title] | Accepted | YYYY-MM-DD |
| DD-002 | [Title] | Proposed | YYYY-MM-DD |

## Decision Log

### Accepted
- DD-001: [Title] - [One-line summary]

### Proposed
- DD-002: [Title] - [One-line summary]

### Deprecated
_None_
```

### 6. Update Task README

Update progress table in `{task_path}/README.md`.

## Decision Quality Checklist

Good decisions:
- [ ] Clearly state the problem being solved
- [ ] List all viable options (not just the chosen one)
- [ ] Explain why alternatives were rejected
- [ ] Acknowledge trade-offs honestly
- [ ] Are reversible or state the cost of reversal
- [ ] Reference supporting research

## 7. Review Artifacts

Launch the reviewer agent to validate design decisions:

```
Task tool:
  subagent_type: general-purpose
  prompt: |
    You are the Sahaidachny Reviewer. Read your instructions from:
    .claude/agents/planning_reviewer.md

    Review mode: decide
    Task path: {task_path}
    Artifacts to review: {task_path}/design-decisions/DD-*.md

    Review the design decisions and report any issues.
```

If the reviewer finds blockers (🔴), revisit the decision before proceeding.

## Example Usage

```
/saha:decide docs/tasks/task-01-auth
/saha:decide --title="Authentication Strategy"
```
