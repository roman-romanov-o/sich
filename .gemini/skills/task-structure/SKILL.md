---
name: Sahaidachny Task Structure
description: |
  Use this skill when working with Sahaidachny task planning. Activated when:
  - User mentions "task", "planning", "user stories", "design decisions"
  - Working in a `task-XX/` directory
  - Any `/saha:*` command is invoked
version: 0.2.0
---

# Sahaidachny Task Structure

Sahaidachny uses a hierarchical task structure for planning complex features before implementation.

## Task Folder Structure

```
task-XX-short-name/
├── README.md                    # Task status dashboard
├── task-description.md          # Architecture + technical overview
├── user-stories/
│   ├── US-001-feature-name.md   # Detailed requirements
│   ├── US-002-feature-name.md   # Acceptance criteria, edge cases
│   └── ...
├── design-decisions/
│   ├── README.md                # Index of decisions
│   ├── DD-001-decision-name.md  # Architecture decisions
│   └── ...
├── code-changes/
│   ├── README.md                # Index of contracts
│   ├── component-a.md           # Interface definitions
│   └── ...
├── implementation-plan/
│   ├── README.md                # Phase status tracking
│   ├── phase-01-name.md         # Execution phases with steps
│   ├── phase-02-name.md
│   └── ...
├── test-specs/
│   ├── README.md                # Test overview
│   ├── environment-setup.md     # Test environment config
│   ├── e2e/                     # End-to-end test specs
│   ├── integration/             # Integration test specs
│   └── unit/                    # Unit test specs
└── research/
    ├── codebase-analysis.md     # Technical research
    └── ...
```

---

## Artifact Templates

### README.md (Task Dashboard)

```markdown
# Task-XX: [Task Title]

**Status:** Planning | In Progress | Completed
**Mode:** Full | Minimal
**Created:** YYYY-MM-DD

## Overview
[1-2 sentence summary]

## Planning Progress

| Step | Status | Artifacts |
|------|--------|-----------|
| Research | Pending/Done | research/*.md |
| Task Description | Pending/Done | task-description.md |
| User Stories | Pending/Done | user-stories/US-*.md |
| Design Decisions | Pending/Done | design-decisions/DD-*.md |
| Code Changes | Pending/Done | code-changes/*.md |
| Test Specs | Pending/Done | test-specs/**/*.md |
| Implementation Plan | Pending/Done | implementation-plan/phase-*.md |

## Next Steps
- [ ] Current action item
```

### task-description.md

```markdown
# Task Description: [Title]

**Status:** Draft | Review | Approved
**Last Updated:** YYYY-MM-DD

## Overview
[Comprehensive description of what this task accomplishes]

## Goals
- Goal 1
- Goal 2

## Non-Goals
- What this task explicitly does NOT cover

## Technical Context
[Relevant technical background, existing systems, constraints]

## Constraints
- Technical constraints
- Business constraints
- Timeline constraints

## Success Criteria
- [ ] Criterion 1
- [ ] Criterion 2
```

### User Story (US-XXX-name.md)

```markdown
# US-XXX: [User Story Title]

**Status:** Draft | Review | Approved
**Priority:** Critical | High | Medium | Low
**Last Updated:** YYYY-MM-DD

## User Story
As a [role], I want [feature] so that [benefit].

## Description
[Detailed description of the feature]

## Acceptance Criteria
- [ ] AC1: [Criterion]
- [ ] AC2: [Criterion]

## Edge Cases
- Edge case 1
- Edge case 2

## Dependencies
- US-XXX (if applicable)
- External dependency

## Related Decisions
- DD-XXX (if applicable)

## Notes
[Additional context or considerations]
```

### Design Decision (DD-XXX-name.md)

```markdown
# DD-XXX: [Decision Title]

**Status:** Draft | Proposed | Accepted | Superseded
**Last Updated:** YYYY-MM-DD

## Context
[What is the issue that we're seeing that motivates this decision?]

## Decision
[What is the change that we're proposing and/or doing?]

## Rationale
[Why is this the best choice among alternatives?]

## Alternatives Considered
1. **Alternative 1:** Description
   - Pros: ...
   - Cons: ...

2. **Alternative 2:** Description
   - Pros: ...
   - Cons: ...

## Consequences
- Positive: ...
- Negative: ...
- Neutral: ...

## Related
- User Stories: US-XXX, US-XXX
- Other Decisions: DD-XXX
```

### Code Change (component-name.md)

```markdown
# Code Change: [Component Name]

**Status:** Draft | Review | Approved
**Last Updated:** YYYY-MM-DD

## Overview
[What this API/interface does]

## Endpoints / Methods

### `METHOD /path` or `function_name()`

**Description:** What this endpoint/method does

**Request/Input:**
```json
{
  "field": "type - description"
}
```

**Response/Output:**
```json
{
  "field": "type - description"
}
```

**Errors:**
| Code | Description |
|------|-------------|
| 400 | Bad request |
| 404 | Not found |

## Related
- User Stories: US-XXX
- Decisions: DD-XXX
```

### Test Spec (test-name.md)

```markdown
# Test Spec: [Test Name]

**Type:** E2E | Integration | Unit
**Status:** Draft | Review | Approved
**Priority:** Critical | High | Medium | Low

## Overview
[What this test verifies]

## Related User Stories
- US-XXX

## Preconditions
- Precondition 1
- Precondition 2

## Test Steps
1. Step 1
2. Step 2
3. Step 3

## Expected Results
- Expected outcome 1
- Expected outcome 2

## Edge Cases to Cover
- Edge case 1
- Edge case 2
```

### Implementation Phase (phase-XX-name.md)

```markdown
# Phase XX: [Phase Name]

**Status:** Pending | In Progress | Completed
**Last Updated:** YYYY-MM-DD

## Overview
[What this phase accomplishes]

## Prerequisites
- Phase XX completed
- External dependency ready

## Steps

### Step 1: [Step Name]
- [ ] Action item 1
- [ ] Action item 2

**Files to create/modify:**
- `path/to/file.py`

### Step 2: [Step Name]
- [ ] Action item 1

## Success Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Related
- User Stories: US-XXX
- Decisions: DD-XXX
```

---

## Planning Modes

### Full Mode
For existing codebases. Includes all steps:
1. Research (codebase exploration)
2. Task Description
3. User Stories + Verification
4. Design Decisions + Verification
5. Code Changes + Verification
6. Test Specs + Verification
7. Implementation Plan + Verification

### Minimal Mode
For greenfield projects. Includes:
1. Task Description
2. User Stories + Verification
3. Definition of Done + Verification

---

## File Naming Conventions

| Artifact | Pattern | Example |
|----------|---------|---------|
| Task folder | `task-XX-short-name/` | `task-05-user-auth/` |
| User Story | `US-XXX-short-name.md` | `US-001-login-form.md` |
| Design Decision | `DD-XXX-short-name.md` | `DD-001-jwt-vs-session.md` |
| Phase | `phase-XX-short-name.md` | `phase-01-setup.md` |
| Test Spec | `descriptive-name.md` | `login-validation.md` |

---

## Status Values

| Status | Meaning |
|--------|---------|
| Draft | Initial creation, not ready for review |
| Review | Ready for review/verification |
| Approved | Verified and accepted |
| Needs Revision | Requires changes after review |

## Priority Values

| Priority | Meaning |
|----------|---------|
| Critical | Must have, blocks other work |
| High | Important, should be done soon |
| Medium | Normal priority |
| Low | Nice to have |
