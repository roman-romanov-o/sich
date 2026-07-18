---
description: Generate user stories as step-by-step LikeC4 workflows
argument-hint: [task-path] [--count=N]
allowed-tools: Read, Write, Edit, Glob, Bash, AskUserQuestion, Task
---

# User Stories

Generate user stories from the task description. Each story is authored twice, in
lockstep:

1. **`model/stories.c4`** — a `dynamic view us-NNN-flow` per story: the step-by-step
   workflow the human actually reviews (this is the point of saha — a reviewable,
   walkable flow, not a wall of markdown).
2. **`progress.yaml`** — the authoritative story/AC records the execution loop
   binds tests to and ticks.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user
- `--count=N`: Number of stories to generate initially (default: auto-detect based on scope)

## Prerequisites

Task model must exist. Check for `{task_path}/model/task.c4`.
If missing, suggest running `/saha:task` first.

## Execution

### 1. Analyze Task

Read and understand:
- `{task_path}/model/task.c4` - Core requirements + the element vocabulary
- `{task_path}/progress.yaml` - Task state
- `{task_path}/research/*.md` - Technical context
- `.claude/templates/stories.c4` - Template/conventions for this artifact

### 2. Identify User Personas

From the task model, identify who will use this feature:
- End users
- Administrators
- Developers (if internal tooling)
- System actors (automated processes)

Personas should already exist as `actor` elements in `task.c4`; add missing ones
in `stories.c4`.

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
2. Adjust priority (must / should / could)
3. Add missing stories

### 5. Author the Story Flows

For each approved story, add to `{task_path}/model/stories.c4`
(following `.claude/templates/stories.c4`):

- A `story` element `us-NNN` with the "As a… I want… so that…" in `description`,
  priority tag (`#must`/`#should`/`#could`) and
  `metadata { priority / depends_on / decisions / edge_cases }`.
- A **`dynamic view us-NNN-flow`** walking the story step by step:
  - Steps reference elements from `task.c4` (`user -> sys.part '…'`); use `<-`
    for responses and `parallel {}` for concurrency.
  - Every step that proves an acceptance criterion cites it in `notes`
    (`**AC-1** — …`) so the reviewer sees WHERE each AC is satisfied.
  - The flow must cover the story end-to-end: trigger → internal effects →
    observable outcome. A story whose view has fewer than 3 steps is usually
    under-specified.
- **Link the helicopter views:** wherever a story CARD appears in a static view
  (the `task-context` view in `task.c4` includes top-level elements via `*`;
  later the `phases` view does too), add an explicit
  `include us-NNN with { navigateTo us-NNN-flow }` line so the reviewer clicks
  the card and lands in the flow. Back-fill `task.c4`'s view now for every
  story you just authored.

### 6. Record Stories in progress.yaml

For each story, append to `stories:` in `{task_path}/progress.yaml`:

```yaml
- id: US-001
  title: "Short title"
  view: us-001-flow
  priority: must            # must | should | could
  status: draft             # draft until reviewed, ready when approved
  story: "As a …, I want …, so that …."
  acceptance_criteria:
    - id: AC-1
      text: "Given …, when …, then …"
      verify: automated     # automated | build | manual
      status: pending
      tests: []
      specs: []             # ts-* view ids, filled by /saha:test-specs
    - id: AC-2
      text: "…"
      verify: manual
      manual_instructions: "exact steps a human follows"
      status: pending
      tests: []
      specs: []
  edge_cases:
    - { name: "…", trigger: "…", expected: "…" }
  depends_on: []
  decisions: []
```

**Verify method — pick the WEAKEST that still gives real confidence:**
- `automated` (default): a headless test asserts it. Logic, APIs, data.
- `build`: it's enough that the project compiles/launches. "App builds", "module links".
- `manual` + `manual_instructions`: no headless test can confirm it (UI rendering,
  visual layout, drill-in feel). The loop routes it to a human and will NOT churn on it.
  Reserve manual for things a machine genuinely cannot check.

The AC ids cited in the view's step notes and the AC ids here MUST match — the
view is the human rendering, the YAML is the machine record of the same story.

### 7. Compile Gate + Progress

```bash
likec4 validate {task_path}/model
```

Fix any errors, then update `{task_path}/progress.yaml`:

```yaml
planning:
  user_stories: { status: in_progress, views: [us-001-flow, us-002-flow, …] }
```

Keep `in_progress` here — `done` is written only in step 8, after the review
passes and the user approves.

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
- Flows that skip the failure/edge path when the story is about handling it

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
    Artifacts to review: {task_path}/model/stories.c4 and the stories section
    of {task_path}/progress.yaml

    Review the story flows and AC records and report any issues.
```

If the reviewer finds blockers (🔴), fix before proceeding. When the review
passes and the user approves, flip each approved story from `status: draft` to
`status: ready` and set `planning.user_stories.status: done` — a `done` step
with `draft` stories means the review never happened.

## Example Usage

```
/saha:stories docs/tasks/task-01-auth
/saha:stories --count=5
```

## Output

Creates or updates:
- `{task_path}/model/stories.c4` (one `us-NNN` element + `us-NNN-flow` dynamic view per story)
- `{task_path}/progress.yaml` (stories records + planning.user_stories)
