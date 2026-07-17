---
description: Document architectural and design decisions
argument-hint: [task-path] [--title=<decision-title>]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion, WebSearch, Task, mcp__context7__resolve-library-id, mcp__context7__query-docs
---

# Design Decisions

Document architectural decisions and their rationale as **LikeC4 decision elements**
wired to the components they shape (`model/decisions.c4`). The reviewer sees each
decision NEXT TO what it affects — not in a separate ADR document.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user
- `--title=<title>`: Create a specific decision

## Prerequisites

- Task folder must exist (with `model/task.c4`)
- User stories should be defined (for context)

## Execution

### 1. Identify Decision Points

Review existing artifacts for decisions that need documenting:
- `{task_path}/model/task.c4` - Constraints and technical context
- `{task_path}/model/stories.c4` + `{task_path}/progress.yaml` - Stories and open questions
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

### 4. Author Decision Elements

Add each decision to `{task_path}/model/decisions.c4`
(following `.claude/templates/decisions.c4`):

```likec4
model {
  dd-001 = decision 'DD-001: {title}' {
    description '''
      **Context:** {problem that motivates this decision}

      **Decision:** {what we are doing}
    '''
    metadata {
      status 'accepted'          // proposed | accepted | superseded
      rationale '{why this beats the alternatives}'
      alternatives '{alt 1 — why rejected}; {alt 2 — why rejected}'
      consequences '{positive}; {negative trade-offs accepted}'
      stories 'US-001; US-002'
    }
  }
  dd-001 -> sys.affected_part 'shapes'
}
```

Rules:
- element id `dd-NNN` — referenced from `progress.yaml` stories[].decisions
- Draw a `-> 'shapes'` relation to **every component the decision constrains**
  (that's the reviewable payoff: the decision sits on the diagram next to its
  blast radius). Add `-> external 'chooses'` for technology picks.
- Be honest in `alternatives`/`consequences` — a decision with no rejected
  alternatives and no negative consequences is a description, not a decision.
- Maintain the `decisions` view: include every `dd-*` and the components they shape.

Then update the affected stories' `decisions:` lists in `{task_path}/progress.yaml`.

### 5. Update the Project Architecture Model (LikeC4)

Separate from the task model: `/saha:decide` is also the **only writer** of the
project-wide architecture model `docs/architecture/*.c4`. One model per project,
many views — never a model per task, never copies of the model into task folders.
(The task's `model/` describes THIS task's slice; `docs/architecture/` describes
the whole system.)

For each decision that is **genuinely architectural** (new component, new
boundary, new external system — not local design choices):

1. If `docs/architecture/` doesn't exist, offer to create it. Convention (not
   a requirement — LikeC4 merges all `*.c4` files in the directory):
   - `model.c4` — elements: systems, containers, components
   - `views.c4` — views over the model
2. Update `model.c4`/`views.c4` **in the same pass** as the decision element.
3. View naming:
   - Evergreen views keep stable ids: `index` (landscape), `context`, one per
     container.
   - Task-scoped views are named `task-NN-<slug>` (e.g. `task-03-quota-flow`)
     and show the slice of architecture this task changes. Keep them after the
     task ships (they document *why* the architecture looks like this); prune
     only when they stop rendering against the current model.
4. Record the affected view ids in the decision's `metadata { arch_views '…' }`.

Skip this step entirely when the decision isn't architectural, or when the
user declines the model — planning works identically without it. Never touch
the model for local design choices.

### 6. Compile Gate + Progress

```bash
likec4 validate {task_path}/model
```

Fix any errors, then update `{task_path}/progress.yaml`:

```yaml
planning:
  design_decisions: { status: done, views: [decisions] }
```

## Decision Quality Checklist

Good decisions:
- [ ] Clearly state the problem being solved
- [ ] List all viable options (not just the chosen one)
- [ ] Explain why alternatives were rejected
- [ ] Acknowledge trade-offs honestly
- [ ] Are reversible or state the cost of reversal
- [ ] Reference supporting research
- [ ] Are wired to every component they constrain

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
    Artifacts to review: {task_path}/model/decisions.c4

    Review the design decisions and report any issues.
```

If the reviewer finds blockers (🔴), revisit the decision before proceeding.

## Example Usage

```
/saha:decide docs/tasks/task-01-auth
/saha:decide --title="Authentication Strategy"
```

## Output

Creates or updates:
- `{task_path}/model/decisions.c4` (view `decisions`)
- `docs/architecture/*.c4` (only for genuinely architectural decisions)
- `{task_path}/progress.yaml` (stories[].decisions + planning.design_decisions)
