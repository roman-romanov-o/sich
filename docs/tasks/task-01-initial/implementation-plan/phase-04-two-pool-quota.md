# Phase 04: Two-Pool Quota Visibility

**Status:** 🟢 READY — **next `/saha:execute` target**. Logic core complete + green (Iteration 1: `QuotaAggregator`, `WindowMath`, source adapters; TC-INT-101..104 + TC-UNIT-101..104 pass). The remaining slice is **Swift/AppKit rendering only**: build `app/Sources/GhostlingApp/QuotaPanel.swift` to render the (already-built) `PoolGauge` data as four distinct gauges, and write TC-E2E-201..204. Phase 01 app shell + Phase 03 board surface now exist to render into.
**Estimated Effort:** M (UI rendering of an existing, tested data model — not new logic).
**Dependencies:** Phase 01 (app shell) ✅ + Phase 03 (board surface to host the panel) ✅. Logic is **independent of Phases 02–03** and already done.

> **Next-session pointer (2026-06-24):** Phase 03 is DONE (drill-in human-signed-off). The single remaining build for `task-01-initial` is this phase's `QuotaPanel.swift`. The next `/saha:execute task-01-initial` should pick this up — render the two Anthropic pools as **distinct, never-netted** gauges (+ best-effort Codex/Gemini), mark inferred values estimated, make exhausted/unknown unmistakable. Bind the new ACs to `swift test` cases + a captured screenshot (pixel AC → human visual sign-off, same loop checkpoint as Phase 03).

## Objective

Deliver the differentiator: a quota panel showing **both** Anthropic pools as distinct gauges (interactive 5h+weekly vs. Agent SDK credit), plus best-effort Codex/Gemini, with confidence on inferred values and clear exhausted/unknown states.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-006 | Must Have | L |

### Out of Scope (Deferred)

- "Projects remaining" prediction (US-007), backlog tagging (US-008), allocator suggestions (US-009) — all build on this but are post-v1.

## Implementation Steps

### Step 1: Quota source adapters

**Description:** Adapters that read each pool's signal: interactive window/weekly state, Agent SDK credit balance, Codex/Gemini usage. Each reports value + `inferred` flag + availability.

**Files to Create/Modify (indicative):**
- `quota/sources/` — one adapter per source. *(If Python sidecar: Pydantic V2 models per source, module-level imports.)*

**Technical Notes:**
- Concrete sources grounded in `research/02`; interactive remaining is partly inferred (window math), Agent SDK credit may be more precise. Confirm exact sources during this step.

**Acceptance Criteria:**
- [x] Each adapter returns a typed value with confidence + availability; an absent source returns `unknown` (not 0, not 100%). *(Iteration 1: QuotaSource Protocol + stub implementations, fully typed)*

### Step 2: Interactive-window math (pure function)

**Description:** Pure computation of remaining for the 5h rolling window + weekly cap + earliest binding reset, with the clock **injected** (no system-clock read).

**Files to Create/Modify (indicative):**
- `quota/WindowMath` — pure module.

**Acceptance Criteria:**
- [x] Fresh window ≈ 100%; usage ages out at +5h; weekly cap dominates when binding; reset = sooner of window/weekly. *(Iteration 1: Pure window_math.py with injected clock, 4 unit tests pass)*

**Tests:** TC-UNIT-101..104 (+ parameterized) ✓

### Step 3: Aggregation + gauges UI

**Description:** Assemble adapters into independent pool models (no netting between pools); propagate confidence; render gauges with remaining/reset, exhausted, and unknown states.

**Files to Create/Modify (indicative):**
- `quota/QuotaAggregator`, `app/QuotaPanel.swift`

**Technical Notes:**
- The two Anthropic pools **do not fungibly trade** — never combine them into one number (`research/10`).
- **Rendering reference: the HELM POC** (`research/UI_POC.html`) shows the target — **four distinct gauges** (interactive 5h+weekly / Agent SDK credit / Codex / Gemini), the two Anthropic ones visually grouped but never netted. Apply the critique fixes: group the two Anthropic gauges; mark inferred values estimated.
- **Scope guard:** v1 = *visibility* (US-006) only. The POC's **capacity-brain recommender** ("→ Start task-07" + `$ saha run …`) is the allocator vision but maps to deferred **US-009/US-007** — do not build the recommendation engine in this phase; the gauges it would feed are what's in scope here.

**Acceptance Criteria:**
- [x] No arithmetic nets one pool against another; confidence shown for inferred values. *(Iteration 1: aggregator.py with independent pool logic, 4 integration tests pass)*
- [ ] Both Anthropic pools shown distinctly in UI; inferred values marked estimated; exhausted/unknown unmistakable. *(Deferred: requires Swift/AppKit QuotaPanel.swift after Phase 01 app shell)*

**Tests:** TC-INT-101..104 ✓; TC-E2E-201..204 (deferred)

## Definition of Done

- [x] **Logic Core (Iteration 1):** US-006 logic layer implemented; TC-INT-101..104, TC-UNIT-101..104 all pass (8 tests); ruff/ty/complexity clean.
- [ ] **UI Rendering (Deferred):** QuotaPanel.swift gauge rendering; TC-E2E-201..204 pass. Pending Phase 01 app shell + Xcode integration.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Interactive-pool remaining only inferable, not precise | High | Medium | Show confidence, not false precision (AC#3); never imply exactness |
| A provider exposes no usable usage signal | Medium | Medium | Represent as `unknown`; don't block the panel |

## Notes

- This is the lowest-risk, highest-differentiation phase and is **off the critical path** — good candidate to build in parallel with Phases 02–03 (or early, for momentum) once the Phase 01 shell exists.

## Related

- **Stories:** US-006 (enables deferred US-007/008/009)
- **Decisions:** DD-001 (pool firewall keeps billing coherent)
- **Design reference:** `research/UI_POC.html` (HELM) — four-pool gauge cluster + capacity brain (recommender deferred)
- **Tests:** TC-E2E-201..204, TC-INT-101..104, TC-UNIT-101..104
