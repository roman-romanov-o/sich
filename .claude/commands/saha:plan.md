---
description: Generate phased implementation plan
argument-hint: [task-path]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion, Task
---

# Implementation Plan

Generate a phased implementation plan from all planning artifacts. The plan is
authored twice, in lockstep:

1. **`model/phases.c4`** — the reviewable overview: phase elements, dependency
   arrows, which stories each phase delivers (view `phases`).
2. **`progress.yaml` `phases:`** — the authoritative machine record the
   execution loop walks and ticks.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user

## Prerequisites

All prior planning steps should be complete (check `planning:` in
`{task_path}/progress.yaml`):
- Task description, user stories, design decisions, code changes, test specs

Run `/saha:status` to verify readiness.

## Execution

### 1. Gather All Artifacts

Read and synthesize:
- `{task_path}/model/*.c4` - The full spec (task, stories, decisions, contracts, test scenarios)
- `{task_path}/progress.yaml` - Stories, ACs, dependencies
- `{task_path}/research/*.md` - Technical context
- `.claude/templates/phases.c4` - Template/conventions for this artifact

### 2. Identify Dependencies

Build the dependency graph from stories' `depends_on` and the contracts:
- Which stories depend on others?
- What infrastructure is needed first?
- What can be parallelized?

### 3. Define Phases

Group work into logical phases:

**Phase Criteria:**
- Each phase should be buildable/testable independently
- Earlier phases establish foundation for later ones
- Critical path items go first
- Related stories are grouped together

**Typical Phase Structure:**
1. **Foundation** - Setup, infrastructure, core models
2. **Core Features** - Must-have functionality
3. **Extended Features** - Should-have functionality
4. **Polish** - Could-have, edge cases, optimization

### 4. Author the Phase Overview

Add to `{task_path}/model/phases.c4` (following `.claude/templates/phases.c4`):

```likec4
model {
  phase-01 = phase 'Phase 01: Foundation' {
    description '''
      **Objective:** {1-2 sentences on what this phase accomplishes}
    '''
    metadata {
      effort 'M'                       // S | M | L | XL
      stories 'US-001'
      risks '{main risk} — {mitigation}'
    }
  }
  phase-01 -> phase-02 'unblocks'      // dependency arrows = the critical path
  phase-01 -> us-001 'delivers'        // wire each phase to its stories
}
```

Maintain the `phases` view: every phase, its dependency arrows, and the stories
delivered. The arrows ARE the dependency graph — no separate diagram needed.

### 5. Record Phases in progress.yaml

For each phase, append to `phases:` in `{task_path}/progress.yaml`:

```yaml
phases:
  - id: phase-01
    title: "Foundation"
    view: phases
    stories: [US-001]
    status: pending          # pending | in_progress | done
    steps:
      - name: "Create SessionRegistry model"
        files: [app/Sources/GhostlingCore/SessionRegistry.swift]
        status: pending
      - name: "Wire registry into BoardShell lifecycle"
        files: [app/Sources/GhostlingApp/BoardShell.swift]
        status: pending
```

Steps are the implementer's work items: concrete, file-scoped, ordered. A step
without a `files` list is usually under-specified. Technical guidance that
doesn't fit a step name belongs in the phase element's `description` in
`phases.c4` — the YAML stays terse and machine-walkable.

### 6. Compile Gate + Progress

```bash
likec4 validate {task_path}/model
```

Fix any errors, then update `{task_path}/progress.yaml`:

```yaml
planning:
  implementation_plan: { status: done, views: [phases] }
```

## Planning Guidelines

Good implementation plans:
- [ ] Have clear phase boundaries
- [ ] Can be executed incrementally
- [ ] Account for testing at each phase
- [ ] Identify the critical path (the arrow chain in the `phases` view)
- [ ] Cover every `must` story in some phase
- [ ] Are realistic about complexity
- [ ] Include rollback considerations for risky steps

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
    Artifacts to review: {task_path}/model/phases.c4 and the phases section
    of {task_path}/progress.yaml

    Review the implementation plan and report any issues.
```

If the reviewer finds blockers (🔴), fix before proceeding.

## Example Usage

```
/saha:plan docs/tasks/task-01-auth
```

## Output

Creates or updates:
- `{task_path}/model/phases.c4` (view `phases`)
- `{task_path}/progress.yaml` (phases records + planning.implementation_plan)
