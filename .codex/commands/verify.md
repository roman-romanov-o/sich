---
description: Verify planning artifacts are complete and consistent
argument-hint: [task-path] [--mode=manual|playwright|script|test]
allowed-tools: Read, Edit, Glob, Grep, Bash, AskUserQuestion, mcp__playwright__browser_navigate, mcp__playwright__browser_snapshot, mcp__playwright__browser_click
---

# Verify Artifacts

Verify the plan is complete, consistent, and ready for implementation. In
saha/v2 the checks are structural: the LikeC4 model must **compile**, and the
cross-references live in `progress.yaml` — no markdown scraping.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user
- `--mode=<mode>`: Verification mode
  - `manual` (default): User reviews and approves
  - `playwright`: UI verification via browser automation
  - `script=<path>`: Run custom verification script
  - `test`: Run test suite

## Execution

### 1. Compile Gate (hard failure)

The model must be well-formed:

```bash
likec4 validate {task_path}/model
```

- Non-zero exit (DSL error, dangling reference) = verify **failure**. (Do not
  use `likec4 export json` for pass/fail — it exits 0 even on model errors.)
- CLI absent (`command -v likec4` fails) → note "likec4 CLI not found — compile
  gate skipped (`npm i -g likec4`)" and continue with the YAML checks. Never
  block planning on node tooling.

### 2. Completeness Check (progress.yaml)

Read `{task_path}/progress.yaml` (it must exist with `format: saha/v2`; if the
folder has the old markdown layout instead, say so and stop — this command
verifies v2 tasks).

**Minimum the execution loop needs:**
- [ ] `planning.task_description.status: done`
- [ ] At least 1 story with at least 1 acceptance criterion
- [ ] At least 1 phase with steps

**Recommended (full mode):**
- [ ] `planning.test_specs` done with at least 1 view
- [ ] `planning.design_decisions` done
- [ ] `planning.code_changes` done (if interfaces change)

Report missing pieces with the command that produces each.

### 3. View-Reference Check

Every view id referenced from YAML must exist in the compiled model:

- Collect referenced ids: all `planning.*.views`, every story's `view`, every
  AC's `specs`, every phase's `view`.
- Collect actual ids: with the CLI, the keys of `views` in
  `likec4 export json --skip-layout -o {scratch}/likec4-verify.json {task_path}/model`
  (delete the file afterwards); without it, `view <id>` / `dynamic view <id>`
  declarations grepped from `{task_path}/model/*.c4`.
- Any referenced-but-missing view id is a failure (the kanban review rail
  deep-links these).

### 4. Cross-Reference Check (all from YAML + model)

**Stories ↔ ACs ↔ Specs:**
- Every AC has a `verify` method (`automated` | `build` | `manual`)
- Every `verify: manual` AC has `manual_instructions`
- Every `verify: automated` AC has at least one entry in `specs` — or the story
  is listed in `planning.test_specs.gaps` with a reason
- **Every story has at least one `ts-e2e-*` view** across its ACs' `specs` — or
  a `planning.test_specs.gaps` entry naming that story with the reason E2E
  isn't feasible. Unit/integration-only coverage for a story is exactly the
  "green tests, broken prod" failure: no scenario walks the full happy path.
- Every `ts-*` view description declares `**Real:**` and `**Mocked:**`; a
  `ts-e2e-*` view whose Mocked list includes system-under-test components
  (not just true externals like network/third-party/clock) is a failure —
  it must be demoted to `ts-int-*` or its environment fixed.
- Spec views' Proves lists (in `model/test-specs.c4` view descriptions) cite
  only AC ids that exist in progress.yaml

**Stories ↔ Phases:**
- Every story appears in exactly one phase's `stories` list
- `depends_on` references existing story ids; phase order respects them

**Stories ↔ Decisions:**
- `decisions:` entries reference `dd-*` elements that exist in `model/decisions.c4`
- Each `dd-*` element's `metadata { stories }` cites existing story ids

**Contracts:**
- Each contract component's `metadata { stories }` cites existing story ids
- Every contract component has at least one relation (no dead spec)

Report inconsistencies:
```
Inconsistencies Found:
- US-003 AC-2 is verify:automated but has no specs and no gap entry
- US-002 has only unit specs (ts-unit-01) — no E2E happy-path view and no gap entry
- ts-e2e-01 mocks QuotaStore, which is part of the system under test
- dd-001 references non-existent US-005
- phase-02 includes US-004 which doesn't exist
```

### 5. Quality Check

- Stories follow "As a… I want… so that…" with priority set
- Each story's `us-NNN-flow` has ≥3 steps and cites its AC ids in step notes
- AC text is Given/When/Then and measurable
- Test scenario Expected notes are implementable without ambiguity
- Phase steps have `files` lists

### 6. Project Architecture Model (optional)

Only when `docs/architecture/` exists (skip silently otherwise):
- `likec4 validate docs/architecture` — non-zero exit is a failure
- View ids in DD `metadata { arch_views }` must exist in that model

### 7. Mode-Specific Verification

#### Manual Mode (default)

Present summary and ask user to confirm:

```
Verification Summary:
✅ model compiles (7 files)
✅ 14/14 referenced views exist
✅ 12/12 cross-references valid
⚠️ 2 quality suggestions

Approve the plan as ready for implementation?
```

Remind the user they can review visually in ghostling's Planning Mode.

#### Playwright Mode

For UI-related tasks, verify planned changes against the existing UI (navigate,
snapshot, compare with research assumptions). Report discrepancies.

#### Script Mode

```bash
bash $SCRIPT_PATH $TASK_PATH
```

Exit 0 = success. Capture and report stdout/stderr.

#### Test Mode

If tests already exist, run them using the project's resolved test command
(`.sahaidachny/stack.yaml` `test.command`, else auto-detect from marker files —
saha is not Python-specific): `pytest -q`, `swift test`, `npm test`,
`cargo test`, `go test ./...`, …

### 8. Record the Result

Report the summary to the user, then update `{task_path}/progress.yaml`
(NOT a separate report file — progress.yaml is the single tracking surface):

```yaml
planning:
  verify: { status: done, result: passed }   # passed | passed_with_warnings | failed
```

On `passed`/`passed_with_warnings` with user approval, the task is ready for
`/saha:execute` — from that point `model/*.c4` is frozen.

## Example Usage

```
/saha:verify docs/tasks/task-01-auth
/saha:verify --mode=manual
/saha:verify --mode=playwright
/saha:verify --mode=script=./scripts/validate-task.sh
/saha:verify --mode=test
```

## Output

- Verification summary displayed
- `{task_path}/progress.yaml` planning.verify updated
