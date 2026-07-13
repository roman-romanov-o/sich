# Phase 01: Task-folder binding

**Status:** Test Critique
**Estimated Effort:** L
**Dependencies:** None

## Execution Progress

| Stage | Status | Last Updated | Notes |
|-------|--------|--------------|-------|
| Implementation | ✅ Passed | 2026-07-06 01:10 | implementation complete |
| Test Critique | ❌ Failed | 2026-07-06 01:11 | score C |
| QA Verification | ⏳ Pending | - | - |
| Code Quality | ⏳ Pending | - | - |
| DoD Check | ⏳ Pending | - | - |

## Objective

Give every newly created saha-flow card an authoritative task-folder binding,
while safely inferring or requesting a binding for cards that predate the
feature.

## Scope

### Stories Included

| Story | Priority | Complexity | Status |
|-------|----------|------------|--------|
| US-001 | Must Have | M | [x] (iteration 4) |
| US-002 | Should Have | S | [x] (iteration 4) |

### Out of Scope (Deferred)

- Planning-state parsing and progress chips backed by full state (Phase 02).
- Planning Mode entry after a successful binding (Phase 03).

## Implementation Steps

### Step 1: Persist the authoritative card binding

**Description:** Add an optional task-folder path to the card model and preserve
it through every card-copy, state-transition, merge, and seed path.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/BoardCard.swift` - add `taskFolder` and preserve it in `with(state:)`
- `app/Sources/GhostlingApp/BoardSeed.swift` - populate or leave bindings unset explicitly
- `app/Sources/GhostlingApp/BoardView.swift` - preserve bindings through board mutations
- `app/Tests/GhostlingCoreTests/TaskFolderBindingTests.swift` - model preservation coverage

**Technical Notes:**
- Store a stable, standardized path representation that remains `Sendable`.
- Do not derive an explicit binding from `.sahaidachny/current-task` after card
  creation; that pointer is shared by the entire project.

**Acceptance Criteria:**
- [x] A bound card keeps the same folder when its state or live-session metadata changes.
- [x] Existing initializers remain source-compatible through a default `nil` binding.

**Tests:**
- US-001 AC4
- TC-E2E-001b

---

### Step 2: Discover, summarize, infer, and scaffold task folders

**Description:** Implement pure discovery/inference logic and an injected
process runner for saha's task scaffold script.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/TaskFolderIndex.swift` - discovery, summaries, and conservative inference
- `app/Sources/GhostlingCore/TaskScaffolder.swift` - typed scaffold invocation contract and errors
- `app/Tests/GhostlingCoreTests/TaskFolderIndexTests.swift` - zero, one, ambiguous, current-task, and malformed-folder cases
- `app/Tests/GhostlingCoreTests/TaskScaffolderTests.swift` - process output and failure cases

**Technical Notes:**
- Return the folder path reported by the successful invocation directly.
- Treat missing progress markers as `unknown`, not as zero completed steps.
- Infer only from exactly one folder, or from exactly one unambiguous
  `current-task` match among multiple folders.

**Acceptance Criteria:**
- [x] Discovery lists conforming and bare `task-*` directories without crashing.
- [x] Ambiguous or absent matches leave an unbound card unbound.
- [x] A non-zero scaffold exit produces a typed error and no binding.

**Tests:**
- TC-INT-001, TC-INT-002, TC-INT-003
- TC-E2E-004, TC-E2E-005, TC-E2E-007, TC-E2E-008

---

### Step 3: Add the card-creation binding UI

**Description:** Extend card creation with an explicit flow choice followed by
an existing-folder picker or create-new form for saha flow.

**Files to Create/Modify:**
- `app/Sources/GhostlingApp/FolderPicker.swift` - task-folder list, progress chips, and create-new state
- `app/Sources/GhostlingApp/BoardShell.swift` - coordinate creation, errors, and board insertion
- `app/Sources/GhostlingApp/BoardView.swift` - expose the create-card entry point
- `app/Tests/GhostlingAppTests/TaskCardCreationTests.swift` - AppKit interaction coverage

**Technical Notes:**
- Do not insert a card until scaffolding succeeds.
- An unbound saha card entering the future Planning Mode should reuse this
  picker instead of guessing.

**Acceptance Criteria:**
- [x] Flow A and Flow B are explicit choices. (iteration 4)
- [x] Saha flow lists existing folders plus create-new; an empty project offers only create-new. (iteration 4)
- [x] Successful selection or creation sets the card's authoritative binding. (iteration 4)
- [x] Scaffold errors are visible and leave the board unchanged. (iteration 4)

**Tests:**
- TC-E2E-001, TC-E2E-002, TC-E2E-003, TC-E2E-006

## Definition of Done

- [x] US-001 and US-002 acceptance criteria pass. (iteration 4)
- [x] All new pure logic has deterministic Swift tests. (iteration 2)
- [x] Card merge/state paths preserve bindings. (iteration 2)
- [ ] `swift test` passes.
- [x] No scaffold failure creates an unbound card. (iteration 4)
- [ ] Test critique, QA verification, code-quality checks, and DoD check pass.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Existing card reconstruction silently drops the new field | Medium | High | Add preservation tests around every copy/merge path |
| Scaffold stdout format changes | Medium | Medium | Isolate parsing behind `TaskScaffolding` and validate the returned directory |
| `current-task` binds the wrong card in multi-card projects | Medium | High | Restrict it to one unambiguous inference match |

## Rollback Plan

1. Hide the new creation controls while leaving the optional model field compatible.
2. Disable inference and require manual selection if discovery proves unreliable.

## Related

- **Stories:** US-001, US-002
- **Decisions:** Pending creation-time-binding decision
- **Contracts:** `task-folder-binding.md`
- **Tests:** `e2e/card-creation-flow.md`, `integration/init-task-invocation.md`
