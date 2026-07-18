---
name: Sahaidachny Task Structure
description: |
  Use this skill when working with Sahaidachny task planning. Activated when:
  - User mentions "task", "planning", "user stories", "design decisions"
  - Working in a `task-XX/` directory
  - Any `/saha:*` command is invoked
version: 0.3.0
---

# Sahaidachny Task Structure (saha/v2)

Sahaidachny plans complex features before implementation. In format **saha/v2** the
plan is not a pile of markdown: the **spec is a LikeC4 model** the human reviews as
diagrams, and **all tracking lives in one YAML file** the tooling reads and writes.

## The Two-File Rule (the core invariant)

- **`model/*.c4` = spec.** Written during planning, reviewed visually, then **frozen**
  when execution starts (the loop fingerprints the files; any edit fails the DoD
  integrity gate). No statuses, no checkmarks, ever.
- **`progress.yaml` = tracking.** The ONLY mutable file. Planning steps, story/AC
  statuses, test bindings, phase progress, iteration history — all here, and only the
  execution loop's manager phase writes it during execution.

Tools (saha commands, the ghostling kanban app, the execution loop) read state from
`progress.yaml` — never by scraping markdown.

## Task Folder Structure

```
task-XX-short-name/
├── progress.yaml          # THE tracking file (format: saha/v2 marker lives here)
├── model/                 # one LikeC4 project, built/validated as a unit
│   ├── spec.c4            # element kinds + tags (actor, component, story, decision, phase…)
│   ├── task.c4            # task description: context model + `view task-context`
│   ├── stories.c4         # one `dynamic view us-NNN-flow` per user story
│   ├── decisions.c4       # DD-XXX decision elements wired to affected components
│   ├── contracts.c4       # interface contracts: components + `metadata { contract '''…''' }`
│   ├── test-specs.c4      # test scenarios as `ts-*` dynamic views
│   └── phases.c4          # plan overview: phase elements + dependency arrows
├── research/*.md          # research stays markdown (prose)
└── README.md              # 5-line human pointer (title, status, "open in ghostling")
```

Templates for every file live in `claude_plugin/templates/` (`spec.c4`, `task.c4`,
`stories.c4`, `decisions.c4`, `contracts.c4`, `test-specs.c4`, `phases.c4`,
`progress.yaml`, plus `research-report.md`).

## progress.yaml Schema

```yaml
format: saha/v2                # presence of this key = new-format task
task: task-11-likec4-planning
title: …
created: 2026-07-17
mode: full                     # full | minimal
status: planning               # planning -> executing -> completed | completed_pending_manual | failed

planning:                      # one entry per planning step; status: pending | in_progress | done | skipped
  research:            { status: done, artifacts: [research/codebase-analysis.md] }
  task_description:    { status: done, views: [task-context] }
  user_stories:        { status: in_progress, views: [us-001-flow, us-002-flow] }
  design_decisions:    { status: pending, views: [] }        # -> [decisions]
  code_changes:        { status: pending, views: [] }        # -> [contracts]
  test_specs:          { status: pending, views: [], gaps: [] }  # gaps: [{story: US-003, reason: …}]
  implementation_plan: { status: pending, views: [] }        # -> [phases]
  verify:              { status: pending }

stories:
  - id: US-001
    title: …
    view: us-001-flow          # dynamic view id in model/stories.c4
    priority: must             # must | should | could
    status: draft              # draft | ready | in_progress | done
    story: "As a …, I want … so that …"
    acceptance_criteria:
      - id: AC-1               # qualified id everywhere else: US-001.AC-1
        text: "Given … when … then …"
        verify: automated      # automated | build | manual
        # manual_instructions: …   (required when verify: manual)
        status: pending        # pending | in_progress | done
        specs: [ts-e2e-01]     # PLANNED coverage (ts-* view ids, filled by /saha:test-specs)
        tests: []              # ACTUAL bindings (filled by the loop: tests/test_x.py::test_y)
    edge_cases: [{ name: …, trigger: …, expected: … }]
    depends_on: []             # [US-000]
    decisions: []              # [DD-001]

phases:
  - id: phase-01
    title: …
    view: phases
    stories: [US-001]
    status: pending            # pending | in_progress | done
    steps:
      - { name: …, files: [path/to/file], status: pending }

iterations: []                 # appended by the loop:
# - { iteration: 1, phase: implementation, result: passed, notes: …, files_changed: [] }
```

Key semantics:
- **`verify:`** is how the loop proves an AC: `automated` = bound named tests go
  red→green; `build` = compilation/launch proves it (empty `tests:` is fine);
  `manual` = human eyes, with exact `manual_instructions` — the loop never ticks it,
  and a task whose only remaining ACs are manual ends as `completed_pending_manual`.
- **`specs:` vs `tests:`** — planned coverage (view ids) vs. actual bindings (real
  runnable test identifiers). Only the manager writes `tests:`, copying passing
  bindings reported by QA.
- The loop's runtime state lives separately in `.sahaidachny/<task>-execution-state.yaml`;
  the toolchain profile in `.sahaidachny/stack.yaml` (or marker-file auto-detect).

## LikeC4 Model Conventions

All `model/*.c4` files form **one project**; `spec.c4` declares the shared kinds
(`actor`, `container`, `component`, `store`, `external`, `story`, `decision`,
`phase`) and tags (`#must #should #could`, `#existing #new`).

### Stable ids bind diagrams ↔ YAML

| Thing | Model id | View id | progress.yaml |
|-------|----------|---------|---------------|
| Task overview | — | `task-context` | `planning.task_description.views` |
| User story | `us-001` (element) | `us-001-flow` (dynamic view) | `stories[].id: US-001`, `view:` |
| Design decision | `dd-001` | `decisions` (one overview view) | `stories[].decisions: [DD-001]` |
| Contracts | components under `extend` | `contracts` | `planning.code_changes.views` |
| Test scenario | — | `ts-e2e-01` / `ts-int-01` / `ts-unit-01` | AC `specs:` lists |
| Phase | `phase-01` | `phases` (one overview view) | `phases[].id` |

### Per-file rules

- **task.c4** — context model of the system under change. Tag every element
  `#existing` or `#new` so the delta is visible; goals/non-goals/constraints go in
  `metadata {}`; the overview view MUST be named `task-context`.
- **stories.c4** — THIS is what the human reviews: each story is a walkable
  `dynamic view` (actor → system → back, `<-` for responses, `parallel {}` for
  concurrency). Cite AC ids in step `notes` (`**AC-1** — …`) so the reviewer sees
  where each criterion is proven — but AC status/text authority stays in the YAML.
- **decisions.c4** — one `decision` element per DD with context/decision in
  `description`, rationale/alternatives/consequences in `metadata {}`, and a
  relation to every component it constrains (`dd-001 -> sys.new_part 'shapes'`).
- **contracts.c4** — one component per created/changed interface; the contract shape
  (signature, input/output fields with types, error cases) goes in
  `metadata { contract '''…''' }` with `contract_kind 'function|rest|event|cli'`;
  relations carry the calls (`caller -> callee 'METHOD /path'`).
- **test-specs.c4** — each scenario is a dynamic view: preconditions/environment in
  the view `description` (with `**Proves:** US-001.AC-1`), per-step `**Expected:**`
  observations in `notes`. Walk the SAME elements as the story flow it verifies.
  The description also declares the test-double boundary: `**Real:**` (what
  executes for real) and `**Mocked:**` (each fake + why, or "nothing"). Every
  story needs a `ts-e2e-*` happy-path scenario (or a `test_specs.gaps` entry);
  an E2E view may mock only true externals — never the system under test.
- **phases.c4** — phase elements with `->` arrows for hard dependencies and
  `phase -> story 'delivers'` relations; step-level detail (files, statuses) stays
  in the YAML.

### Validation

```bash
likec4 validate {task_path}/model
```

is THE well-formedness gate (used by `/saha:verify` and reviewers). Do NOT gate on
`likec4 export json` — it exits 0 even on broken models.

Authoring gotchas:
- Re-opening a nested element from another file requires `extend sys.new_part { … }`,
  not re-declaration.
- `kind` is a reserved key inside `metadata {}` — use `contract_kind`.
- Element ids must not be LikeC4 property keywords (`summary`, `title`,
  `description`, `technology`, `link`, `icon`, `style`, `metadata`,
  `navigateTo`) — `validate` fails with a cryptic `Expecting token '}'`.
  Prefix instead: `repo_summary`, not `summary`.
- Prose belongs in `description '''…'''` and step `notes '''…'''` (markdown renders);
  structured facts belong in `metadata {}`.

---

## Choosing a Planning Path

Two **independent** considerations decide how much planning a task needs. Don't
conflate them:

- **Scope** — small (a 1-2 file fix, a tiny feature) vs. large (multi-component).
- **Context** — greenfield (new area, little existing code) vs. existing codebase
  (patterns and architecture matter).

| | Small scope | Large scope |
|---|---|---|
| **Greenfield** | `/saha:quick` | full planning flow |
| **Existing codebase** | `/saha:quick` | full planning flow |

Scope, not context, picks the path. The codebase scan adapts to context: for an
existing codebase it grounds artifacts in real files; for greenfield it proceeds
from the description without inventing references.

### Quick Path (small tasks)

One command, one pass, no separate review gate:

1. `/saha:quick "<one-line task>"` — light codebase scan, then the minimum the loop
   needs: `model/spec.c4` + `model/task.c4` + one `us-001-flow` in `model/stories.c4`,
   and a `progress.yaml` with one story (ACs with `verify:` methods = the definition
   of done) and one phase.
2. `/saha:execute` — the full verify loop runs unchanged.

### Full Path (large tasks)

The multi-step planning chain, each step verified before the next:

1. Research (`/saha:research` → `research/*.md`)
2. Task Description (`/saha:task` → `model/task.c4`)
3. User Stories + Verification (`/saha:stories` → `model/stories.c4` + YAML records)
4. Design Decisions + Verification (`/saha:decide` → `model/decisions.c4`)
5. Code Changes + Verification (`/saha:contracts` → `model/contracts.c4`)
6. Test Specs + Verification (`/saha:test-specs` → `model/test-specs.c4` + AC `specs:`)
7. Implementation Plan + Verification (`/saha:plan` → `model/phases.c4` + YAML phases)

Both paths feed the **same** execution loop. The loop's only requirement is a
`progress.yaml` with `format: saha/v2`, at least one story whose ACs carry `verify:`
methods, and at least one phase — plus a model that passes `likec4 validate`.

---

## Naming Conventions

| Thing | Pattern | Example |
|-------|---------|---------|
| Task folder | `task-XX-short-name/` | `task-05-user-auth/` |
| Story id / view | `US-XXX` / `us-xxx-flow` | `US-001` / `us-001-flow` |
| Qualified AC id | `US-XXX.AC-N` | `US-001.AC-2` |
| Decision id | `DD-XXX` / element `dd-xxx` | `DD-001` / `dd-001` |
| Phase id | `phase-XX` | `phase-01` |
| Test view | `ts-{e2e,int,unit}-NN` | `ts-e2e-01` |

## Legacy Tasks

A task folder **without** a `format: saha/v2` progress.yaml is old-format (markdown
artifacts: `task-description.md`, `user-stories/*.md`, …). `/saha:execute` refuses
those and routes them to the old Python path (`saha run`); the kanban app still
renders them via its legacy marker-scraping fallback. New planning always produces
saha/v2.
