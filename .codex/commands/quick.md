---
description: One-pass lightweight planning for a small task, then hand off to /saha:execute
argument-hint: "<one-line task>" [--path=docs/tasks]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Saha Quick

Plan a **small task** (a 1-2 file fix, a tiny feature) in a **single inline pass**
and hand straight off to the execution loop. This collapses the full planning
chain (`init → task → research → stories → verify → plan`) into one generation of
the *minimum* artifacts `/saha:execute` needs:

- a minimal task model (`model/task.c4` + one story flow in `model/stories.c4`),
- `progress.yaml` with **one story whose acceptance criteria are the Definition
  of Done** and **exactly one phase**.

This command is **plan-only**. It does NOT write product code, does NOT run the
execution loop, and does NOT launch a `planning_reviewer` pass. When it finishes
it tells you to run `/saha:execute`.

> For large or multi-component work, use the full planning flow
> (`/saha:init` → `/saha:task` → `/saha:research` → `/saha:stories` →
> `/saha:verify` → `/saha:plan`) instead.

## Arguments

- **task description** (required, positional): a one-line description of the small
  change, e.g. `/saha:quick "add a --json flag to the status command"`.
- `--path=<path>`: base path for the task folder (default: `docs/tasks`).

## Edge cases

- **Missing description.** If no task description is given (empty `$ARGUMENTS`, or
  only flags), STOP immediately with a clear message asking for a one-line
  description, e.g.:
  `Usage: /saha:quick "<one-line task>". Please describe the small change in one line.`
  Do **not** create any folder or artifact.
- **Scope looks large.** If the description clearly spans many components (e.g.
  "rewrite the auth system", "migrate the whole DB layer", several unrelated
  deliverables), still produce a single collapsed plan, but note in the task
  model's description and in your final message that the scope looks large and
  the full planning flow (`/saha:init` … `/saha:plan`) may fit better.

## Execution recipe

Do all of the following in **this one pass**. Do not pause for approval between steps.

### Step 1 — Validate input

Parse `$ARGUMENTS`. Separate the positional task description from any `--path=`
flag. If there is no non-flag text, handle the **Missing description** edge case
above and stop.

### Step 2 — Light, targeted codebase scan (grounding)

Run a **brief, targeted** scan — not a full research phase. Pull 3-8 keywords from
the task description and use `Grep`/`Glob` to locate the real files, symbols, and
patterns the change will touch. Examples:

- `Glob` for likely files/dirs by name.
- `Grep` for the function/class/command/flag names mentioned.
- `Read` only the few files that look directly relevant (skim, don't deep-dive).

Goals and limits:

- Ground the artifacts in **actual files and patterns** — reference real paths you
  found, not invented placeholders.
- If the task is in a brand-new area with no existing code, proceed from the
  description and do **not** fabricate file references.
- If the description names something the scan can't locate, note the gap in the
  artifacts rather than assuming it exists.
- Keep it short. This grounds the plan; it is not a research deliverable. Do **not**
  write a `research/` artifact.

**Also detect the project's stack** (saha is not Python-specific). Glob the repo root
for a marker file and note the toolchain so the AC/DoD reference real commands:

| Marker | test | quality |
|--------|------|---------|
| `pyproject.toml` / `setup.py` | `pytest -q` | `ruff check`, `ty`, `complexipy` |
| `Package.swift` / `*.xcodeproj` | `swift test` | `swiftlint` |
| `package.json` | `npm test` | `eslint`, `tsc --noEmit` |
| `Cargo.toml` | `cargo test` | `cargo clippy` |
| `go.mod` | `go test ./...` | `go vet`, `golangci-lint run` |

If the detected stack is **non-Python** and `.sahaidachny/stack.yaml` does not exist,
write one now so `/saha:execute` resolves the right commands. Example for Swift:

```yaml
# .sahaidachny/stack.yaml
build:   { command: "swift build" }
test:    { command: "swift test", file_globs: ["**/*Tests.swift"] }
quality: { commands: ["swiftlint"], changed_files_only: true }
run:     { command: "swift run" }
```

Use `test.command: ""` for a target that genuinely has no headless tests (UI-only).

### Step 3 — Scaffold the task folder

Create the folder structure and set it as the current task by running the init
script. Derive a short slug from the task description for the task name:

```bash
bash .claude/scripts/init_task.sh "<short-slug-from-description>" --path=<path or docs/tasks>
```

This creates the saha/v2 layout (`model/spec.c4`, `progress.yaml`, `research/`)
and writes `.sahaidachny/current-task`. Capture the created `task-XX-<slug>` id
and its path from the script output (it prints `Created task folder:` and
`Task ID:`).

### Step 4 — Write the minimal task model

Create `<task_path>/model/task.c4`: the actor, the `sys` container, and ONLY the
components the scan found affected (tag `#existing`/`#new`,
`metadata { files '…' }` with the real paths), plus `view task-context`. Keep it
tiny — a quick task's model is a handful of elements. Note "Planned via
/saha:quick" and any scope-looks-large warning in the container description.

Create `<task_path>/model/stories.c4`: one `us-001 = story` element and one
`dynamic view us-001-flow` (3-5 steps: trigger → change → observable outcome),
citing the AC ids in step notes.

If `likec4` is on PATH, run `likec4 validate <task_path>/model` and fix errors;
if absent, note it and continue.

### Step 5 — Fill `progress.yaml` (the Definition of Done)

Edit `<task_path>/progress.yaml` (init created the skeleton). US-001's
**acceptance criteria are the Definition of Done** — the execution loop parses
this file, nothing else:

```yaml
status: planning
planning:
  task_description:    { status: done, views: [task-context] }
  user_stories:        { status: done, views: [us-001-flow] }
  design_decisions:    { status: skipped }
  code_changes:        { status: skipped }
  test_specs:          { status: skipped }
  implementation_plan: { status: done, views: [] }
  verify:              { status: skipped }

stories:
  - id: US-001
    title: "<short title>"
    view: us-001-flow
    priority: must
    status: ready
    story: "As a developer, I want <the change>, so that <the benefit>."
    acceptance_criteria:
      - { id: AC-1, text: "<concrete outcome, real files from the scan>", verify: automated, status: pending, specs: [], tests: [] }
      - { id: AC-2, text: "<concrete outcome>", verify: build, status: pending, specs: [], tests: [] }
      - { id: AC-3, text: "Tests and quality checks pass on the changed files (<detected stack commands>)", verify: automated, status: pending, specs: [], tests: [] }
    edge_cases: []
    depends_on: []
    decisions: []

phases:
  - id: phase-01
    title: "<short phase name>"
    view: phases
    stories: [US-001]
    status: pending
    steps:
      - { name: "<what to change>", files: [<real/path/from/scan>], status: pending }
```

Rules:

- Emit **2-5** acceptance criteria. Each must be concrete and verifiable,
  grounded in the files found in Step 2. Avoid vague items the loop can't check.
- Always include a final AC for "tests + quality checks pass", phrased for the
  **detected stack** — do not hardcode Python tools unless the project is Python.
- **Set each AC's `verify` method**: `automated` (default) for anything a
  headless test asserts; `build` for "it compiles/launches"; `manual` +
  `manual_instructions` for UI rendering / visual things no headless test can
  confirm. Manual ACs end the loop in `completed_pending_manual` for human
  sign-off instead of churning to max-iter.
- Quick mode always produces exactly one phase; no `model/phases.c4` needed
  (leave `implementation_plan.views: []`).

### Step 6 — Stop and hand off (do NOT execute)

Print a short summary and stop. Do **not** start `/saha:execute`, do **not** write
product code, do **not** launch any reviewer agent. End with the next step:

```
═══════════════════════════════════════════════
SAHA QUICK — plan ready (single pass)
  Task: <task-XX-slug>  (now the current task)
  Artifacts: model/task.c4, model/stories.c4, progress.yaml
  [if scope looked large] Note: scope looks large — full planning may fit better.

  Next step: /saha:execute
═══════════════════════════════════════════════
```

## Notes

- **One pass, no gate.** Everything above happens in a single invocation with no
  separate review-and-approve step. The verification you keep is the *execution*
  loop (test-critique → QA → code-quality → DoD), which runs later under
  `/saha:execute`.
- **Reuses the loop unchanged.** The story/AC/phase records use the same
  progress.yaml schema the execution agents parse, so `/saha:execute` runs and
  terminates cleanly with no agent changes.
- **Quick = small scope, not greenfield.** This is the path for *small changes in
  an existing codebase*. Greenfield vs. existing codebase is a separate axis; the
  light scan in Step 2 handles existing-codebase grounding either way.

## Example Usage

```
/saha:quick "add a --json flag to saha status output"
/saha:quick "fix the off-by-one in pagination in api/list.py"
/saha:quick "rename Config.timeout to Config.timeout_seconds everywhere"
```
