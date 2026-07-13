# Phase 03: Planning Mode

**Status:** Test Coverage Review (implementation complete, test gaps flagged)
**Estimated Effort:** L
**Dependencies:** Phase 02

## Execution Progress

| Stage | Status | Last Updated | Notes |
|-------|--------|--------------|-------|
| Implementation | ✅ Complete | 2026-07-07 iter 2 | Steps 1–3 code delivered: three-pane altitude, real SessionRegistry terminal, stepClicked rewritten with unsent-input no-op |
| Test Critique | ⚠️ Score C | 2026-07-07 iter 2 | Code fixes landed but test-coverage gaps remain: interaction-AC-binding violations (back gesture uses returnToBoard() call not cmd-[; step tests call mouseDown directly not window.sendEvent) + missing E2E edge tests (TC-E2E-001b, TC-E2E-006, TC-E2E-007) |
| QA Verification | ✅ Pass (code) | 2026-07-07 iter 2 | swift test 219/219 green; real TC-INT-002 test added; code complete but test-coverage work remains |
| Code Quality | ✅ Passed | 2026-07-07 iter 2 | 0 blocking issues |
| DoD Check | ⏳ Blocked | - | Blocked by test-coverage gaps; implementation code is done, test fixes in next phase |

## Objective

Add a full-window planning altitude with a live stepper, raw artifact viewer,
and registered interactive terminal that suggests the next command without
executing it.

## Scope

### Stories Included

| Story | Priority | Complexity | Status |
|-------|----------|------------|--------|
| US-004 | Must Have | L | [ ] |

### Out of Scope (Deferred)

- Styled markdown and Mermaid output (Phase 04); raw read-only text is the phase
  placeholder.
- Execution-mode UI after `/saha:verify`.

## Implementation Steps

### Step 1: Add the Planning Mode altitude ✓ (iteration 1)

**Description:** Extend `BoardShell` with planning enter/exit mechanics parallel
to drill-in and compose three panes without disturbing board state.

**Files to Create/Modify:**
- `app/Sources/GhostlingApp/BoardShell.swift` - planning altitude lifecycle and `⌘[` return
- `app/Sources/GhostlingApp/PlanningModeView.swift` - three-pane container ✓
- `app/Sources/GhostlingApp/PlanningStepperView.swift` - ordered live step controls
- `app/Sources/GhostlingApp/PlanningDocumentView.swift` - raw read-only artifact placeholder
- `app/Tests/GhostlingAppTests/PlanningModeTests.swift` - altitude and hierarchy tests ✓

**Technical Notes:**
- Reuse the proven board hide/show mechanics, but keep drill-in and planning
  state mutually exclusive.
- If the card is unbound, present Phase 01's picker before constructing the mode.
- Make unknown states visibly distinct from pending.

**Acceptance Criteria:**
- [x] A bound card opens a three-pane full-window mode with correct step states. (iteration 1)
- [ ] An unbound card opens binding UI instead of guessing.
- [x] `⌘[` tears down watchers and returns to the unchanged board. (iteration 1)

**Tests:**
- TC-E2E-010, TC-E2E-011, TC-E2E-014 (verified in iteration 1)

---

### Step 2: Register and embed the planning terminal ✓ (iteration 2, code complete)

**Description:** Construct the terminal through the existing interactive session
path and bind it to the card/project context.

**Files to Create/Modify:**
- `app/Sources/GhostlingApp/PlanningModeView.swift` - terminal-pane ownership ✓
- `app/Sources/GhostlingApp/TerminalSurface.swift` - expose safe input-buffer inspection/insertion seam ✓
- `app/Sources/GhostlingCore/SessionRegistry.swift` - reuse registration without a new spawn mechanism ✓
- `app/Tests/GhostlingAppTests/PlanningTerminalTests.swift` - registry and pool-firewall assertions ✓

**Technical Notes:**
- The terminal is a normal registered interactive session.
- Do not add `claude -p`, background dispatch, or an implicit Enter key.

**Acceptance Criteria:**
- [x] The planning terminal is visible and registered exactly once. (iteration 2)
- [x] Existing pool-firewall restrictions remain effective. (iteration 2)
- [x] Leaving Planning Mode releases view ownership without killing unrelated sessions. (iteration 2)

**Tests:**
- US-004 AC2 ✓ (real SessionRegistry terminal + TC-INT-002 test added, iteration 2)
- Existing `SessionRegistryTests` and `PoolFirewallTests` passing

---

### Step 3: Implement suggest-only step interaction ✓ (iteration 2, code complete; test gaps flagged)

**Description:** Select every clicked step's artifact, but pre-type a command
only for the current next-incomplete step and only when the input buffer is empty.

**Files to Create/Modify:**
- `app/Sources/GhostlingApp/PlanningStepperView.swift` - click routing and eligibility ✓
- `app/Sources/GhostlingApp/PlanningModeView.swift` - artifact selection and command insertion ✓ (rewritten)
- `app/Sources/GhostlingApp/TerminalSurface.swift` - unsent insertion API and occupied-buffer response ✓
- `app/Tests/GhostlingAppTests/PlanningStepInteractionTests.swift` - interaction coverage (test gaps remaining)

**Technical Notes:**
- Read the command from `PlanningState`; do not duplicate the mapping in the view.
- Completed steps only select documents.
- Occupied input produces a no-op plus visible feedback and preserves every byte.

**Acceptance Criteria (US-004 AC3/AC4):**
- [x] Clicking next-incomplete selects its doc and inserts the command without submitting. (code done, iteration 2)
- [x] Clicking a completed step selects its doc and does not change terminal input. (code done, iteration 2)
- [x] Existing unsent input is never overwritten and the user receives feedback. (code done, TC-E2E-013, iteration 2)

**Test-Coverage Gaps (Iteration 2 Critique):**
- Interaction-AC-binding violations: back gesture tested via returnToBoard() direct call (not real cmd-[); step tests call mouseDown directly (not window.sendEvent)
- Missing E2E edge tests: TC-E2E-001b (card-B doesn't break card-A), TC-E2E-006 (no-docs-folder), TC-E2E-007 (bare-folder chip)
- NOTE: Test critique's claims that TC-UNIT-001-006 and TC-INT-011/012 are missing are FALSE POSITIVES — those tests exist in PlanningStateReaderTests.swift

**Tests:**
- TC-E2E-012, TC-E2E-012b, TC-E2E-013 code added (test-coverage re-validation needed per critique)

## Definition of Done

- [ ] US-004 acceptance criteria pass with test-coverage validation (code done, test-coverage gaps block completion)
- [x] Planning enter/exit and watcher teardown are deterministic. (Step 1 iteration 1)
- [x] Existing drill-in behavior and keyboard navigation do not regress. (swift test 219/219 green, iteration 2)
- [x] `swift test` passes (219/219 green, iteration 2)
- [x] Registry and pool-firewall tests pass and SessionRegistry terminal is live (Step 2 iteration 2)
- [x] No command is auto-submitted in tests or production paths (Step 3 code done with unsent-input no-op, iteration 2)
- [x] Code-quality checks passed (0 blocking issues, iteration 2)
- [ ] Test-coverage gaps resolved: interaction-AC-binding (real input events) + missing E2E edge tests (TC-E2E-001b, TC-E2E-006, TC-E2E-007)
- [ ] Test critique and final DoD check pass (test-coverage fixes in next iteration)

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| New altitude conflicts with drill-in ownership | Medium | High | Centralize mutually exclusive altitude state in `BoardShell` |
| Input insertion accidentally submits or overwrites text | Medium | High | Narrow API, occupied-buffer guard, byte-preservation tests |
| Watchers or terminal views leak after return | Medium | Medium | Explicit teardown and repeated enter/exit tests |

## Rollback Plan

1. Hide Planning Mode entry while retaining the Phase 01/02 models.
2. Disable command insertion independently; keep stepper and document review read-only.

## Related

- **Stories:** US-004
- **Decisions:** Pending suggest-only Planning Mode decision
- **Contracts:** `planning-state-reader.md`, `task-folder-binding.md`
- **Tests:** `e2e/planning-mode-flow.md`
