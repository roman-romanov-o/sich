# Unit Test Spec: Planning marker parser

**File:** `app/Sources/GhostlingCore/PlanningStateReader.swift`
**Priority:** High
**Status:** Draft

## Overview

Pure-function tests for the markdown-marker → `PlanningState` parsing logic (US-003), isolated from the filesystem/file-watcher wiring covered by the integration spec. Complex-enough parsing logic (multiple marker formats, a fixed step table) to justify unit tests per this project's "unit tests only when necessary" philosophy.

## Test Cases

### TC-UNIT-001: parseStatus - well-formed `**Status:**` line

**Input:** `parseStatus("**Status:** Draft")`

**Expected:** `.draft`

---

### TC-UNIT-002: parseStatus - missing marker

**Input:** `parseStatus("no status line here")`

**Expected:** `.unknown`

**Notes:** Must not throw (US-003 edge case 1).

---

### TC-UNIT-003: parseReadmeTable - full progress table

**Input:** README fixture with all 8 canonical rows, mixed Done/Pending

**Expected:** `PlanningState` with 8 entries, statuses matching the table exactly

---

### TC-UNIT-004: nextIncompleteStep - middle of pipeline

**Input:** state where Research/Task Description/User Stories = done, rest pending

**Expected:** `.designDecisions` (the `PlanningStep` case; wire form is `"design_decisions"` per `wireName`)

---

### TC-UNIT-005: nextIncompleteStep - all done

**Input:** state where all 8 steps = done

**Expected:** `nil`

---

### TC-UNIT-006: commandForStep - table lookup

**Input:** `commandForStep(.designDecisions)`

**Expected:** `"/saha:decide"`

**Notes:** Locks in the step→command table added to US-003 after the reviewer's blocker.

## Parameterized Cases

| Step | Expected Command |
|------|------------------|
| research | `/saha:research` |
| taskDescription | `/saha:task` |
| userStories | `/saha:stories` |
| designDecisions | `/saha:decide` |
| codeChanges | `/saha:contracts` |
| testSpecs | `/saha:test-specs` |
| implementationPlan | `/saha:plan` |
| verify | `/saha:verify` |

## Mocks Required

- None — pure function over string/file content
