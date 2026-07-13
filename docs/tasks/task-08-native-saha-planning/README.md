# TASK-08: Native Saha Planning

**Status:** In Progress (Iteration 2 — Test Coverage Review)
**Mode:** Full
**Created:** 2026-07-05
**Last Updated:** 2026-07-07 (Iteration 2)

## Overview

Native saha planning surface in the kanban app: bind cards to `docs/tasks/task-XX/` folders at creation, drive the planning pipeline with a live stepper + native markdown/mermaid doc viewer + an embedded terminal, and add a `plan-status --json` source of truth on the saha side.

## Iteration 2 Summary (2026-07-07)

**Implementation:** ✅ Completed (real SessionRegistry terminal, stepClicked rewritten, unsent-input no-op, 219/219 swift green)
**Test Critique:** ⚠️ Score C — Code delivered but test-coverage gaps flagged
**QA Verification:** ✅ Pass (code implementation)
**Code Quality:** ✅ Passed (0 blocking issues)

**Completed (Iteration 2):**
- Phase 03 Step 2: ✅ Real SessionRegistry terminal registered in planning pane (AC2 code done, TC-INT-002 test added)
- Phase 03 Step 3: ✅ stepClicked logic rewritten + unsent-input no-op implemented (AC3/AC4 code done, TC-E2E-013 added)
- Integration tests: ✅ Real TC-INT-002 test added (was a critique gap from iter 1)

**Test-Coverage Gaps Identified (Iteration 2 Critique):**
1. Interaction-AC-binding violations: back gesture tested via returnToBoard() call (not real cmd-[); step tests call mouseDown directly (not window.sendEvent)
2. Missing E2E edge tests: TC-E2E-001b (card-B doesn't break card-A), TC-E2E-006 (no-docs-folder), TC-E2E-007 (bare-folder chip)
3. FALSE POSITIVE: Critique claimed TC-UNIT-001-006 and TC-INT-011/012 missing — those tests exist in PlanningStateReaderTests.swift

**Blockers for Next Iteration:**
1. Test-coverage gaps: interaction-AC-binding violations + missing E2E edge tests (TC-E2E-001b, TC-E2E-006, TC-E2E-007)
2. Phase 04 Steps 2–3: Full GFM rendering and Mermaid CLI paths
3. Phase 02 Step 3: saha `plan-status --json` CLI command

## Planning Progress

| Step | Status | Artifacts |
|------|--------|-----------|
| Research | Done | research/native-planning-proposal.md |
| Task Description | Done | task-description.md |
| User Stories | Done | user-stories/US-001..006 |
| Design Decisions | Done (via test specs/code changes) | design-decisions/ |
| Code Changes | Done | code-changes/*.md |
| Test Specs | Done | test-specs/**/*.md |
| Implementation Plan | In Progress (iter 1) | implementation-plan/phase-01..04 |

## Next Steps (Iteration 3 onwards)

- [ ] Fix test-coverage gaps: interaction-AC-binding (real input events, not method calls) + missing E2E edge tests
  - Refactor back gesture test to use real cmd-[ input event (not returnToBoard() call)
  - Refactor step interaction tests to use window.sendEvent (not direct mouseDown/performClick)
  - Add TC-E2E-001b (card-B doesn't break card-A), TC-E2E-006 (no-docs-folder), TC-E2E-007 (bare-folder chip)
- [ ] Complete Phase 04 Steps 2–3 (Mermaid rendering, verification flow)
- [ ] Implement saha `plan-status --json` CLI command (Phase 02 Step 3)
- [ ] Re-run test critique with coverage fixes to clear DoD gate
