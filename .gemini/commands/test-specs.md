---
description: Generate test specifications as scenario flows in the task model
argument-hint: [task-path] [--type=e2e|integration|unit]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion, Task
---

# Test Specifications

Author test scenarios as **LikeC4 dynamic views** (`model/test-specs.c4`): each
scenario is a walkable flow through the same elements the stories use —
preconditions and environment in the view description, expected results in the
assert steps' notes. The reviewer checks a test spec the same way they check a
story: by walking the diagram.

## Testing Philosophy: E2E First

**The test pyramid is inverted during planning.** We think top-down:

1. **E2E tests are the top priority.** Every user story should have at least one E2E scenario that simulates the full flow a user goes through.
2. **Integration tests fill gaps** where E2E can't provide reliable coverage (hard-to-trigger error paths, race conditions, third-party boundaries).
3. **Unit tests only when necessary** — complex algorithms, tricky pure-logic edge cases.

**The key question per story:** "Can I write an E2E test that walks the entire
flow?" If yes, start there. Only drop down when E2E isn't feasible.

> **Match the project's stack.** Saha is language-agnostic — write specs against
> the project's own test framework (`swift test`/XCTest, Vitest/Jest, `cargo test`,
> `go test`, pytest, …). Resolve the stack from `.sahaidachny/stack.yaml` or the
> repo's marker files, and name it in the scenario's `metadata { framework }`.
>
> **ACs with `verify: manual` in progress.yaml get NO spec.** Do not invent a
> brittle automated scenario for visual/feel criteria — the loop routes those to
> a human. List them in the coverage gaps instead.

## Arguments

- **task-path** (optional): Path to task folder
  - If not provided, auto-detects using:
    1. Current task from `.sahaidachny/current-task` (set via `saha use`)
    2. Most recent task folder in `docs/tasks/`
  - If no context found, asks the user
- `--type=<type>`: Focus on a specific test type (e2e, integration, unit)

## Prerequisites

- Stories with ACs exist (`model/stories.c4` + progress.yaml stories)
- Optionally: contracts (`model/contracts.c4`) for integration scenarios

## Execution

### 1. Analyze Test Requirements

Read:
- `{task_path}/progress.yaml` - Every AC with `verify: automated` needs coverage;
  `verify: build`/`manual` do NOT get scenarios
- `{task_path}/model/stories.c4` - The flows to mirror
- `{task_path}/model/contracts.c4` - Interface behaviors and error responses
- `.claude/templates/test-specs.c4` - Template/conventions for this artifact

### 2. Author Scenarios (Top-Down)

Add to `{task_path}/model/test-specs.c4`. View id convention (progress.yaml and
the kanban reference these):

- `ts-e2e-NN` — end-to-end scenarios
- `ts-int-NN` — integration scenarios
- `ts-unit-NN` — unit scenarios (rare)

```likec4
model {
  // The test harness is an actor in the flows:
  harness = external 'Test Harness' {
    description 'swift test / pytest / vitest — whatever the stack resolves to'
  }
}

views {
  dynamic view ts-e2e-01 {
    title 'TS-E2E-01: Session appears on the board'
    description '''
      **Proves:** US-001 AC-1, AC-2

      **Preconditions:** clean registry; hook installed.

      **Environment:** `swift test --filter BoardE2ETests`; no network.
    '''
    harness -> sys.receiver 'POST session-start hook payload'
    sys.receiver -> sys.registry 'registers session'
    harness -> sys.board 'reads board state' {
      notes '''
        **Expected:** exactly one card, column = running, title = repo dir name.
        **Expected:** re-sending the same payload does not duplicate the card.
      '''
    }
  }
}
```

Conventions:
- Steps reuse the elements from `task.c4`/`contracts.c4`; the `harness` element
  drives the flow. Error scenarios are their own views (drive the failing input,
  assert the recovery).
- **Proves** lists the exact `US-NNN AC-N` ids the scenario covers — this is the
  coverage matrix, distributed across the views.
- Every scenario ends in at least one step whose `notes` carry `**Expected:**`
  assertions concrete enough to implement without ambiguity (specific values,
  states, error codes — include test data inline where it matters).
- Add scenario `metadata { framework / stories / priority }` on a companion
  element if the view alone is insufficient — but prefer keeping everything in
  the view.

### 3. Record Coverage in progress.yaml

For each scenario, add its view id to the ACs it proves:

```yaml
stories:
  - id: US-001
    acceptance_criteria:
      - id: AC-1
        verify: automated
        specs: [ts-e2e-01]     # planned coverage (the loop later fills tests:)
```

Then check the matrix: every `verify: automated` AC must appear in at least one
scenario's Proves list. **Every story needs E2E coverage or an explicit gap
reason** — record gaps in `planning.test_specs.gaps`:

```yaml
planning:
  test_specs:
    status: done
    views: [ts-e2e-01, ts-e2e-02, ts-int-01]
    gaps:
      - { story: US-003, reason: "third-party API cannot be called E2E; covered by ts-int-01" }
```

### 4. Compile Gate

```bash
likec4 validate {task_path}/model
```

Fix any errors before review.

## Test Spec Guidelines

Good test scenarios:
- [ ] Every story has E2E coverage (or an explicit gap reason in YAML)
- [ ] E2E flows go trigger → system → observable outcome, start to finish
- [ ] Integration scenarios only cover what E2E can't reach reliably
- [ ] Unit scenarios only for complex isolated logic (not glue code)
- [ ] Proves lists map 1:1 to real AC ids in progress.yaml
- [ ] Happy path AND error cases each have a view
- [ ] Expected notes are implementable without ambiguity

**Anti-patterns:**
- Unit/integration-only coverage for a story with a walkable user flow
- Testing implementation details instead of user-visible behavior
- Over-mocking — 5+ mocks means it should be an integration test with real deps
- Scenarios for `verify: manual` ACs

## 5. Review Artifacts

Launch the reviewer agent to validate test specifications:

```
Task tool:
  subagent_type: general-purpose
  prompt: |
    You are the Sahaidachny Reviewer. Read your instructions from:
    .claude/agents/planning_reviewer.md

    Review mode: test-specs
    Task path: {task_path}
    Artifacts to review: {task_path}/model/test-specs.c4 and the AC specs/gaps
    entries in {task_path}/progress.yaml

    Review the test scenarios and coverage and report any issues.
```

If the reviewer finds blockers (🔴), fix before proceeding.

## Example Usage

```
/saha:test-specs docs/tasks/task-01-auth
/saha:test-specs --type=e2e
```

## Output

Creates or updates:
- `{task_path}/model/test-specs.c4` (views `ts-e2e-NN` / `ts-int-NN` / `ts-unit-NN`)
- `{task_path}/progress.yaml` (AC specs bindings + planning.test_specs with gaps)
