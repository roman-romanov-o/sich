# E2E Test Spec: Saha-flow card creation and binding

**Related Stories:** US-001, US-002
**Priority:** Critical
**Status:** Draft

## Overview

Full flow of creating a saha-flow card and having it end up bound to a `docs/tasks/task-XX/` folder, via both the explicit creation path (US-001) and the inference fallback for pre-existing cards (US-002). Runtime: `swift test` in `app/Tests/GhostlingAppTests` (or GhostlingCoreTests for the pure parts), driving real `NSEvent`s for interactive steps per this project's interaction-AC binding rule — never call a handler method directly to stand in for a click.

## Preconditions

- A temp project directory with a `docs/tasks/` folder containing 0–2 existing task-XX folders (varies per test case)
- `saha`'s `init_task.sh` reachable (or a fixture stand-in script for CI determinism — see Test Data)
- `BoardShell` test harness able to construct with an injected temp project root

## Test Cases

### TC-E2E-001: Create new card → create-new task folder

**Description:** User creates a card, picks saha flow, picks "create new", names it, and the card ends up bound.

**Steps:**
1. Dispatch the real `NSEvent` sequence that opens "new card" creation UI
2. Dispatch click on the saha-flow option
3. Dispatch click on "create new", type a name, confirm (real keyDown events for typed characters)
4. Await scaffold completion (init script run)
5. Read the resulting `BoardCard`

**Expected Results:**
- A new `docs/tasks/task-NN-<slug>/` folder exists with the standard saha scaffold (README, user-stories/, etc.)
- The created `BoardCard.taskFolder` equals that folder's path (this is the authoritative binding — see TC-E2E-001b for why `current-task` is not)

**Test Data:**
```json
{ "input": { "flow": "saha", "mode": "create-new", "name": "sample-feature" },
  "expected": { "taskFolderSuffix": "-sample-feature" } }
```

**Additional assertion (US-001 AC1):** before step 2's click, assert both the "saha flow" and "interactive flow" options are rendered as an explicit choice — not just that clicking saha-flow happens to work.

---

### TC-E2E-001b: Creating card B does not break card A's binding via `current-task`

**Description:** Regression guard for the reviewer-flagged multi-card `current-task` hazard (US-001 AC3).

**Steps:**
1. Complete TC-E2E-001 to create card A, bound to `task-NN-sample-feature` (this also sets `.sahaidachny/current-task` to it)
2. Create card B via "create new" with a different name, producing `task-MM-other-feature`

**Expected Results:**
- Card A's `BoardCard.taskFolder` still equals `task-NN-sample-feature` (unchanged) even though `.sahaidachny/current-task` now points at `task-MM-other-feature`
- Entering Planning Mode on card A still opens `task-NN-sample-feature`, proving `taskFolder` — not `current-task` — is what's read

---

### TC-E2E-002: Create new card → pick existing task folder

**Description:** User creates a card, picks saha flow, and selects an existing task folder from the picker.

**Steps:**
1. Seed temp `docs/tasks/task-03-existing/` with a README (some steps Done)
2. Dispatch creation flow events, choose saha flow
3. Dispatch click selecting `task-03-existing` from the picker list
4. Confirm

**Expected Results:**
- Picker showed a progress chip for `task-03-existing` reflecting its README table (e.g. "2/8")
- New `BoardCard.taskFolder` equals `task-03-existing`'s path
- No new folder was scaffolded

---

### TC-E2E-003: `init_task.sh` failure surfaces, does not silently bind

**Description:** Scaffold script fails (non-zero exit); creation flow must not produce a silently-unbound card.

**Steps:**
1. Point the harness at a script fixture that exits non-zero
2. Dispatch create-new flow, confirm

**Expected Results:**
- Creation flow surfaces a visible failure state
- No `BoardCard` is added to the board as a result of this attempt

---

### TC-E2E-004: Pre-existing unbound card infers binding on load

**Description:** A card created before this feature (no `taskFolder`) gets a binding inferred at board load per US-002.

**Steps:**
1. Seed a project dir with exactly one `docs/tasks/task-05-only/` folder and a `BoardCard` with `taskFolder == nil`
2. Load the board

**Expected Results:**
- After load, that card's `taskFolder` is inferred to `task-05-only`

---

### TC-E2E-005: Ambiguous inference leaves card unbound

**Description:** Two task folders exist, neither matches `.sahaidachny/current-task`; US-002 says don't guess.

**Steps:**
1. Seed two task folders, no matching `current-task` file
2. Load the board, then attempt to enter Planning Mode on the ambiguous card

**Expected Results:**
- Card remains unbound after load (no `taskFolder` set)
- Entering Planning Mode prompts the picker instead of guessing

### TC-E2E-006: No `docs/tasks/` folder yet → picker offers only "create new"

**Description:** US-001 edge case 1.

**Steps:**
1. Seed a temp project dir with no `docs/tasks/` folder at all
2. Dispatch creation flow, pick saha flow

**Expected Results:**
- The existing-task picker option is absent/disabled; "create new" is the only path shown

---

### TC-E2E-007: Existing folder with no README/status markers still binds, chip shows "unknown"

**Description:** US-001 edge case 3.

**Steps:**
1. Seed `docs/tasks/task-09-bare/` with no README and no status markers
2. Dispatch creation flow, pick saha flow, select `task-09-bare` from the picker

**Expected Results:**
- Picker's progress chip for `task-09-bare` reads "unknown" (or equivalent 0-state), not a crash or a fabricated fraction
- Binding still completes: new `BoardCard.taskFolder` equals `task-09-bare`'s path

---

### TC-E2E-008: Zero task folders exist → card stays unbound, Planning Mode offers create-new

**Description:** US-002 edge case — no folders to infer from at all.

**Steps:**
1. Seed a temp project dir with an empty `docs/tasks/` (or none)
2. Load the board with a pre-existing card that has `taskFolder == nil`
3. Attempt to enter Planning Mode on that card

**Expected Results:**
- Card remains unbound after load (no inference possible)
- Entering Planning Mode offers the US-001 create-new path rather than an empty/broken picker

## Cleanup

- Remove temp project directories and any `.sahaidachny/` state created during the test
