---
description: Generate phased implementation plan
argument-hint: [task-path]
allowed-tools: Read, Write, Glob, Grep, AskUserQuestion, Task
---

# Implementation Plan

Generate a phased implementation plan from all planning artifacts.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user

## Prerequisites

All prior planning steps should be complete:
- Task description
- User stories
- Design decisions (full mode)
- code changes (full mode)
- Test specifications

Run `/saha:status` to verify readiness.

## Execution

### 1. Gather All Artifacts

Read and synthesize:
- `{task_path}/task-description.md` - Scope and constraints
- `{task_path}/user-stories/*.md` - Features to implement
- `{task_path}/design-decisions/*.md` - Technical approach
- `{task_path}/code-changes/*.md` - Interfaces to build
- `{task_path}/test-specs/**/*.md` - Test requirements
- `{task_path}/research/*.md` - Technical context

### 2. Identify Dependencies

Build dependency graph:
- Which stories depend on others?
- What infrastructure is needed first?
- What can be parallelized?

### 3. Define Phases

Group work into logical phases:

**Phase Criteria:**
- Each phase should be deployable/testable independently
- Earlier phases establish foundation for later ones
- Critical path items go first
- Related stories are grouped together

**Typical Phase Structure:**
1. **Foundation** - Setup, infrastructure, core models
2. **Core Features** - Must-have functionality
3. **Extended Features** - Should-have functionality
4. **Polish** - Could-have, edge cases, optimization

### 4. Create Phase Files

Create `{task_path}/implementation-plan/phase-XX-{name}.md`:

```markdown
# Phase XX: [Phase Name]

**Status:** Not Started | In Progress | Complete
**Estimated Effort:** [T-shirt size: S/M/L/XL]
**Dependencies:** Phase XX-1 (if applicable)

## Objective

[What this phase accomplishes - 1-2 sentences]

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-XXX | Must Have | M |
| US-YYY | Must Have | S |

### Out of Scope (Deferred to Later Phases)

- US-ZZZ (Phase 3)

## Implementation Steps

### Step 1: [Component/Feature Name]

**Description:** [What to build]

**Files to Create/Modify:**
- `src/path/to/new-file.ts` - [Purpose]
- `src/path/to/existing.ts` - [What changes]

**Technical Notes:**
- [Implementation guidance]
- [Patterns to follow]

**Acceptance Criteria:**
- [ ] [Verifiable outcome]
- [ ] [Another outcome]

**Tests:**
- TC-UNIT-XXX
- TC-INT-XXX

---

### Step 2: [Next Component]

[...]

## Definition of Done

Phase is complete when:
- [ ] All stories implemented
- [ ] All tests passing
- [ ] Code reviewed
- [ ] Documentation updated
- [ ] Deployed to staging

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| [Risk] | Medium | High | [How to handle] |

## Notes

[Any additional context or decisions made during planning]

## Related

- **Stories:** US-XXX, US-YYY
- **Decisions:** DD-XXX
- **Contracts:** [code-change.md]
- **Tests:** [test-spec.md]
```

### 5. Create Implementation Plan README

Create `{task_path}/implementation-plan/README.md`:

```markdown
# Implementation Plan

Phased execution plan for [Task Name].

## Overview

| Phase | Name | Status | Stories |
|-------|------|--------|---------|
| 01 | Foundation | Not Started | US-001 |
| 02 | Core Features | Not Started | US-002, US-003 |
| 03 | Extended Features | Not Started | US-004, US-005 |

## Dependency Graph

```
Phase 01: Foundation
    ↓
Phase 02: Core Features
    ↓
Phase 03: Extended Features
```

## Timeline

```
Phase 01 ████████░░░░░░░░░░░░░░░░
Phase 02 ░░░░░░░░████████████░░░░
Phase 03 ░░░░░░░░░░░░░░░░████████
```

## Critical Path

The following items block all downstream work:
1. [Critical item from Phase 1]
2. [Foundation component]

## Risks Summary

| Phase | Key Risks |
|-------|-----------|
| 01 | [Main risk] |
| 02 | [Main risk] |

## Execution Notes

- [Guidance for executing the plan]
- [Dependencies on external teams/resources]
```

### 6. Update Task README

Update `{task_path}/README.md`:
- Set "Implementation Plan" to complete
- Add phase summary to overview

## Planning Guidelines

Good implementation plans:
- [ ] Have clear phase boundaries
- [ ] Can be executed incrementally
- [ ] Account for testing at each phase
- [ ] Identify the critical path
- [ ] Are realistic about complexity
- [ ] Include rollback considerations

## 7. Review Artifacts

Launch the reviewer agent to validate the implementation plan:

```
Task tool:
  subagent_type: general-purpose
  prompt: |
    You are the Sahaidachny Reviewer. Read your instructions from:
    .claude/agents/planning_reviewer.md

    Review mode: plan
    Task path: {task_path}
    Artifacts to review: {task_path}/implementation-plan/phase-*.md

    Review the implementation plan and report any issues.
```

If the reviewer finds blockers (🔴), fix before proceeding.

## Example Usage

```
/saha:plan docs/tasks/task-01-auth
```

## Output

Creates:
- `{task_path}/implementation-plan/phase-XX-{name}.md` (one per phase)
- `{task_path}/implementation-plan/README.md`
- Updates `{task_path}/README.md`
