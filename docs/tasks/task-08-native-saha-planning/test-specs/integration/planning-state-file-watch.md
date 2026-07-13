# Integration Test Spec: PlanningStateReader + FileWatcher wiring

**Related:** US-003
**Priority:** High
**Status:** Draft

## Overview

E2E (TC-E2E-011) already covers the user-visible "stepper updates live" behavior. This spec covers the narrower, race-prone wiring between `FileWatcher` events and `PlanningStateReader` re-parses — timing/debounce behavior that's hard to assert reliably at the full-UI level, and the `plan-status --json` preference-vs-fallback branch (US-003 AC3), which needs both saha-present and saha-absent environments.

## Dependencies

- Real filesystem, real `FileWatcher` (no mock — matches this project's "real dependencies in integration tests" philosophy)
- A fixture `saha` binary/script on PATH for the JSON-preference case, and a PATH without it for the fallback case

## Test Cases

### TC-INT-010: Rapid successive file writes coalesce to one re-parse

**Description:** Multiple saves in a burst (e.g. an editor autosaving, or a script writing several files) should not cause redundant/overlapping parses.

**Setup:**
```swift
let reader = PlanningStateReader(watching: tempTaskFolder)
```

**Input:**
```json
{ "writes": ["README.md", "task-description.md", "README.md"], "intervalMs": 10 }
```

**Expected Output:**
```json
{ "reparseCount": "<= number of FileWatcher-coalesced events, not one-per-write" }
```

**Assertions:**
- Final `PlanningState` reflects the last write's content
- No crash/race under rapid writes

---

### TC-INT-011: Prefers `plan-status --json` when saha supports it

**Description:** US-003 AC3.

**Setup:** fixture `saha` script on PATH that responds to `plan-status --json` with a fixed payload

**Expected Output:**
```json
{ "source": "saha-json", "nextStep": "design_decisions" }
```

**Assertions:**
- Reader's output matches the fixture JSON's `next_step`, not an independent marker-scrape result (prove precedence, not just correctness of either path alone)

---

### TC-INT-012: Falls back to marker-scraping when saha lacks the flag

**Description:** US-003 edge case 2.

**Setup:** fixture `saha` on PATH that exits non-zero / unknown-flag error for `plan-status --json`

**Expected Output:**
```json
{ "source": "marker-scrape" }
```

**Assertions:**
- No user-visible error surfaces
- Reader output matches direct parsing of the same folder's markers

## Data Fixtures

```bash
# fixture-saha-with-json.sh — echoes a canned plan-status JSON payload
# fixture-saha-without-json.sh — exits 2 on unknown flag
```
