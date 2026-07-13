# Phase 02: Planning-state contract

**Status:** Test Critique (partial implementation)
**Estimated Effort:** L
**Dependencies:** Phase 01

## Execution Progress

| Stage | Status | Last Updated | Notes |
|-------|--------|--------------|-------|
| Implementation | ⚠️ Partial | 2026-07-06 iter 1 | Steps 1–2 complete (marker reader, file-watch refresh, PlanningStateReader tests); JSON CLI contract (Step 3) remains pending in saha repo |
| Test Critique | ✅ Passed | 2026-07-06 iter 1 | score B; US-003 AC1–3 verified green; flagged missing TC-INT-002 test coverage |
| QA Verification | ✅ Passed | 2026-07-06 iter 1 | swift test 213/213 green |
| Code Quality | ✅ Passed | 2026-07-06 iter 1 | 0 blocking issues |
| DoD Check | ⏳ Pending | - | Awaiting Phase 03 AC3/AC4 resolution and Phase 04 verification |

## Objective

Produce one live `PlanningState` model for a bound folder, preferring saha's
structured JSON when available and reliably falling back to local markers.

## Scope

### Stories Included

| Story | Priority | Complexity | Status |
|-------|----------|------------|--------|
| US-003 | Must Have | M | [ ] |
| US-006 | Should Have | S | [ ] |

### Out of Scope (Deferred)

- Rendering the stepper and command interactions (Phase 03).
- Markdown rendering (Phase 04).

## Implementation Steps

### Step 1: Define and parse planning state ✓ (iteration 1)

**Description:** Add the fixed eight-step model, wire names, command mapping,
next-incomplete calculation, JSON decoder, and marker-scraping fallback.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/PlanningState.swift` - step/status model and command table
- `app/Sources/GhostlingCore/PlanningStateReader.swift` - JSON and marker parsing orchestration ✓
- `app/Tests/GhostlingCoreTests/PlanningStateReaderTests.swift` - parser and fallback tests ✓
- `app/Tests/GhostlingCoreTests/Fixtures/planning-state/` - representative task artifacts and JSON

**Technical Notes:**
- Decode `checks[].name` through explicit wire names.
- Preserve `unknown` per step when markers are absent or malformed.
- Treat CLI failure, unsupported command, empty stdout, and malformed JSON as
  fallback signals; folder I/O errors must still be observable for diagnostics.

**Acceptance Criteria:**
- [x] The model always has the fixed pipeline order and correct command mapping.
- [x] A partial README produces the correct next incomplete step.
- [x] Missing or malformed markers produce `unknown` without throwing.

**Tests:**
- TC-UNIT-001 through TC-UNIT-006 (verified green in iteration 1)

---

### Step 2: Add event-driven folder refresh ✓ (iteration 1)

**Description:** Watch the bound task folder, debounce burst writes, re-read
state once, and notify both future UI consumers from one callback.

**Files to Create/Modify:**
- `app/Sources/GhostlingApp/FileWatcher.swift` - support the folder-watch lifecycle or extract a reusable watcher
- `app/Sources/GhostlingApp/PlanningStateController.swift` - bridge filesystem events to the core reader
- `app/Tests/GhostlingAppTests/PlanningStateFileWatchTests.swift` - deterministic event/debounce coverage ✓

**Technical Notes:**
- Keep filesystem mechanics in the AppKit/platform layer; keep parsing pure in
  `GhostlingCore`.
- Reuse the existing watcher cadence and expose a test seam instead of asserting
  wall-clock timing.
- Cancel the prior watch when switching cards or leaving Planning Mode.

**Acceptance Criteria:**
- [x] A write refreshes state within the existing watcher cadence. (iteration 1)
- [x] Rapid writes coalesce and never overlap parses. (iteration 1)
- [x] No additional fast polling loop is introduced. (iteration 1)

**Tests:**
- TC-INT-010, TC-INT-011, TC-INT-012 (deterministic tests added in iteration 1)

---

### Step 3: Add `saha plan-status --json`

**Description:** In the sahaidachny repository, expose the existing verifier's
results as the documented stable JSON contract.

**Files to Create/Modify:**
- `saha/commands/execution.py` or a focused command module in the sahaidachny repository - command implementation
- sahaidachny CLI registration module - register `plan-status`
- sahaidachny pytest suite - partial, complete, and unresolved-task contract tests

**Technical Notes:**
- Emit exactly eight ordered checks using the contract's wire names.
- Emit no stdout on resolution or validation failure.
- Keep this an optional app fast path: shipping or locating a newer saha binary
  must not be required for local marker parsing.

**Acceptance Criteria:**
- [ ] Partial and complete tasks emit valid, stable JSON with the correct `next_step`.
- [ ] Unresolvable tasks exit non-zero with no partial JSON.
- [ ] The Swift reader prefers valid JSON and falls back silently when unsupported.

**Tests:**
- TC-INT-020, TC-INT-021, TC-INT-022

## Definition of Done

- [x] US-003 acceptance criteria AC1–3 pass (iteration 1, verified green in QA).
- [ ] US-006 acceptance criteria pending (saha plan-status --json still in Step 3).
- [x] Swift parser and watcher tests pass (iteration 1, swift test 213/213 green).
- [ ] Saha pytest contract tests pass (Step 3 work, still pending).
- [x] `swift test` passes (iteration 1, 213/213 green).
- [x] No new sub-250ms polling loop exists (iteration 1, verified in QA).
- [x] Test critique passed (score B, iteration 1).
- [ ] Final DoD check pending (awaiting Phase 03 AC3/AC4 resolution and saha JSON contract).

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| App and CLI wire names drift | Medium | High | Contract fixtures and explicit wire-name decoding in both repositories |
| Directory events are noisy or platform-dependent | High | Medium | Debounce and deterministic watcher seams |
| External saha repo cannot be released with the app | Medium | Medium | Preserve and test marker fallback as a first-class path |

## Rollback Plan

1. Disable JSON invocation and use marker scraping without changing the UI model.
2. Fall back to explicit refresh on folder-watch failure while retaining diagnostics.

## Related

- **Stories:** US-003, US-006
- **Decisions:** Pending JSON-source/fallback decision
- **Contracts:** `planning-state-reader.md`, `plan-status-json-cli.md`
- **Tests:** `unit/planning-marker-parser.md`, `integration/planning-state-file-watch.md`, `integration/saha-plan-status-json.md`
