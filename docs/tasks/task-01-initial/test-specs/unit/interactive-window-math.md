# Unit Test Spec: Interactive-Pool Window Math

**File:** TBD (pure fn: usage events + clock → remaining % for 5h rolling window + weekly cap) — implementation-plan decides module/stack
**Priority:** High
**Status:** Draft

## Overview

The pure arithmetic behind US-006's interactive gauge: compute remaining capacity for a **5-hour rolling window** plus a **weekly cap**, and a reset time, from a usage series and a reference time. Isolated because rolling-window math is exactly the "tricky algorithm" the testing philosophy reserves unit tests for, and it must be deterministic (clock injected, never read from the system).

> Note: the system clock is a **parameter**, not a global read — keeps tests deterministic and matches the no-hidden-time-source rule.

## Test Cases

### TC-UNIT-101: Fresh window → near-full remaining

**Input:** `remaining(usage=[], now=T0, window=5h, weekly_cap=...)`
**Expected:** window remaining ≈ 100%; reset = T0 + 5h (or no active window).

### TC-UNIT-102: Usage ages out of the rolling window

**Input:** usage spike at `T0`, evaluate at `T0 + 5h01m`.
**Expected:** that spike no longer counts against the window; remaining recovers.

### TC-UNIT-103: Weekly cap dominates when window is fresh

**Input:** window fresh but weekly usage near cap.
**Expected:** effective remaining is bounded by the **weekly** cap, not the window.

### TC-UNIT-104: Reset time is the earliest binding reset

**Input:** both window and weekly partially used.
**Expected:** reported reset = the **sooner-to-bind** of {window reset, weekly reset}.

## Parameterized Cases

| usage pattern | now | expected remaining basis | description |
|---|---|---|---|
| empty | T0 | window≈100%, weekly≈100% | fresh |
| spike@T0 | T0+1h | window reduced | within window |
| spike@T0 | T0+5h01m | window recovered | aged out |
| steady near weekly cap | T0 | weekly-bound | weekly dominates |
| both partial | T0 | min(window,weekly) | binding constraint |

## Mocks Required

- None — `now` is injected. No network, no system clock read.
