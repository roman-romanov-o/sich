# Phase 02: State Detection

**Status:** Logic Core Complete; Live Wiring & UI Deferred
**Estimated Effort:** L
**Dependencies:** Phase 01 (session registry + PTY read).
**Iteration Complete:** 2

## Objective

Make each session's state trustworthy and automatic: ingest Claude Code hook events, reconcile with JSONL/PTY signals, classify into a state enum, and write it onto the session registry. This is the critical-feasibility layer (task-description Research Question 2).

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-004 | Must Have | L |

### Out of Scope (Deferred)

- Codex/Gemini detection (v1 = Claude Code only).
- Board rendering and the attention count (Phase 03 consume this phase's output).

## Implementation Steps

### Step 1: Claude Code hook ingestion

**Description:** Receive Claude Code hook events for managed sessions (HTTP hook receiver) and normalize them into typed signal events.

**Files to Create/Modify (indicative):**
- `detector/HookReceiver` — local endpoint; normalizes payloads to a typed `SignalEvent`. *(If a Python sidecar: Pydantic V2 models, module-level imports, functions ≲50 lines.)*

**Technical Notes:**
- Hooks are the primary signal (HIGH confidence per `research/06`); precedence: hooks → JSONL → PTV reconciliation.

**Acceptance Criteria:**
- [x] A canonical hook sequence is received and normalized in order. ✓ (iteration 2)

**Tests:** TC-INT-001 ✓

### Step 2: State classifier (pure function)

**Description:** The pure `classify(prior, event) → state` mapping, including ambiguous/stale → `unknown`. No I/O.

**Files to Create/Modify (indicative):**
- `detector/StateClassifier` — pure module, fully unit-tested.

**Technical Notes:**
- Single responsibility, no mocks needed. If a mock is required, the boundary is wrong → it belongs in reconciliation (Step 3).

**Acceptance Criteria:**
- [x] All parameterized cases pass; ambiguous/contradictory → `unknown`, never a guess. ✓ (iteration 2)

**Tests:** TC-UNIT-001 ✓, TC-UNIT-002 ✓, TC-UNIT-003 ✓ (+ parameterized table)

### Step 3: Reconciliation (hook gaps, rapid transitions, stale)

**Description:** Tie hooks + JSONL tail + PTY signals together with precedence and timing; self-correct on dropped/late hooks; coalesce rapid transitions; flip to `stale`/`unknown` on silence past threshold.

**Files to Create/Modify (indicative):**
- `detector/StateReconciler` — orchestrates sources, writes state to `SessionRegistry`.

**Acceptance Criteria:**
- [x] Dropped `stop` hook → converges to `done` via JSONL. ✓ (iteration 2)
- [x] Silence past threshold → `unknown`; rapid transitions coalesce to final state. ✓ (iteration 2)

**Tests:** TC-INT-002 ✓, TC-INT-003 ✓, TC-INT-004 ✓; TC-E2E-004 (board-level unknown deferred to Phase 03)

## Definition of Done

- [x] Detection logic + reconciliation core complete; TC-INT-001..004 + TC-UNIT-001..003 pass. ✓ (iteration 2)
- [x] State written to the registry and observable by Phase 03. ✓ (iteration 2)
- [x] Confidence/`unknown` handling is first-class (not silently defaulting to a wrong state). ✓ (iteration 2)
- [x] Live HTTP hook endpoint (POST /hooks, GET /sessions[/{id}]) + test coverage complete. ✓ (iteration 3 — 59 pytest green; US-004 AC#1/2/3 + TC-INT-001..004 verified at live HTTP layer)
- [ ] App-side PTY wiring into Swift shell (deferred: gated on Swift app shell rendering, Phase 03).
- [ ] Card UI rendering the session state (deferred: gated on Swift app shell Phase 00/01).

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Hook coverage gaps for some Claude Code states | Medium | High | JSONL/PTY reconciliation as fallback; explicit `unknown` rather than wrong state |
| Detection too noisy/flaky on real sessions | Medium | Medium | Coalescing + thresholds; validate against recorded real-session fixtures |

## Notes

- Codex/Gemini detection deferred but the `SignalEvent`/classifier seam should not hard-code Claude specifics, to ease later providers.
- **Iteration 2 outcome:** Full Python state-detection logic is implemented and tested (**29 detector tests green** — 21 unit + 8 integration, per `STATUS.md`: deterministic; injected-clock for staleness detection; ambiguous→unknown first-class; hook normalization + JSONL tail reconciliation + PTY precedence all working). The live-wiring (HTTP endpoint in app, real PTY/hook delivery to Python sidecar) and card UI consuming the detected state are blocked on the Swift app shell (Phase 00/01). Once the shell exists, the live-wiring is a thin integration layer (~50 LOC async handler).

## Related

- **Stories:** US-004
- **Decisions:** DD-001 (in-app PTY read enables this)
- **Tests:** TC-INT-001..004, TC-UNIT-001..003, TC-E2E-004
