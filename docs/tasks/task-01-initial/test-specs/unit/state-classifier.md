# Unit Test Spec: Session State Classifier

**File:** TBD (the pure mapping fn: signal event → state enum) — implementation-plan decides module/stack
**Priority:** High
**Status:** Draft

## Overview

The pure function at the heart of US-004: given a single normalized signal (or small window of signals) and the prior state, return the next state enum. Isolated here because the *mapping rules* (incl. ambiguous→`unknown`) are fiddly and deserve exhaustive, fast coverage that the integration test shouldn't have to enumerate.

> Justification for a unit spec (not glue): this is non-trivial branching logic with edge cases, exactly what the testing philosophy permits unit tests for. The reconciliation/timing behavior stays in integration (TC-INT-00x); only the pure classification lives here.

## Test Cases

### TC-UNIT-001: permission-request → waiting-for-input

**Input:** `classify(prior="running", event=PermissionRequest)`
**Expected:** `waiting-for-input`

### TC-UNIT-002: stop event → done

**Input:** `classify(prior="running", event=Stop)`
**Expected:** `done`

### TC-UNIT-003: no signal past threshold → unknown

**Input:** `classify(prior="running", event=StaleTimeout)`
**Expected:** `unknown` (never invented `done`)

## Parameterized Cases

| prior | event | expected | description |
|-------|-------|----------|-------------|
| idle | SessionStart | running | start |
| running | ToolUse | running | stays running |
| running | PermissionRequest | waiting-for-input | needs human |
| waiting-for-input | UserInput | running | resumed |
| running | TestRunStart | running-tests | optional sub-state |
| running | ErrorExit | blocked | crash/error |
| running | Stop | done | clean finish |
| running | StaleTimeout | unknown | ambiguous, don't guess |
| any | ContradictorySignals | unknown | conflict → unknown |

## Mocks Required

- None — pure function over typed inputs (no I/O). If mocks are needed, the boundary is wrong and the case belongs in integration.
