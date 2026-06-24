# US-006: Two-pool quota visibility

**Priority:** Must Have
**Persona:** Capacity Planner
**Status:** Draft
**Estimated Complexity:** L

## User Story

As a **Capacity Planner**,
I want to **see how much capacity remains in each quota pool I draw on**,
So that **I know what I can spend this cycle and which pool to route work to**.

## Acceptance Criteria

1. **Given** I use Claude on a subscription,
   **When** I open the quota panel,
   **Then** I see **both** Anthropic pools as distinct gauges: **interactive** (5h rolling window + weekly cap) and **Agent SDK credit** (capped monthly, hard-stop), each with remaining amount and reset time.

2. **Given** I also run Codex / Gemini,
   **When** I open the quota panel,
   **Then** their pools appear as additional gauges (best-effort from available sources), clearly labeled by provider.

3. **Given** a pool's remaining capacity is partly inferred (e.g. interactive window math, not a clean API),
   **When** it is displayed,
   **Then** the gauge shows confidence / "estimated", not false precision.

## Edge Cases

1. **A pool is exhausted**
   - Trigger: Agent SDK credit hits zero (hard-stop) or interactive window is locked out.
   - Expected behavior: the gauge clearly shows exhausted + reset/refill time; this state is what later feeds routing suggestions (US-009, deferred).

2. **Data source unavailable**
   - Trigger: a provider exposes no usable usage signal this cycle.
   - Expected behavior: that gauge shows "unknown / not tracked" rather than implying 100% free.

## Technical Notes

- The **two-pool split is load-bearing** (`research/10`): the pools do not fungibly trade, so they must be shown separately. This is the differentiator no tracker (single-pool) or orchestrator (quota-blind) has.
- Interactive remaining is partly **inferred** (window math) — see `research/02` on data availability. Confidence display is a requirement (AC #3), not optional polish.
- v1 = **display only**. Prediction ("projects remaining", US-007) and routing suggestions (US-009) build on this but are deferred.

## Dependencies

- **Requires:** quota data sources (Claude usage signals; ccusage-style for Codex/Gemini).
- **Enables:** US-007 (projects-remaining), US-008/US-009 (allocator).

## Questions

- [ ] Which concrete sources for interactive-window remaining vs. Agent SDK credit in v1? (Grounded in `research/02`; confirm during implementation-plan.)

## Implementation Status (Iteration 1)

**Logic Core:** COMPLETE
- **Models** (`quota/models.py`): Pydantic V2 gauge types with confidence/availability.
- **Window Math** (`quota/window_math.py`): Pure 5h rolling + weekly cap logic, clock-injected.
- **Aggregator** (`quota/aggregator.py`): Two-pool independent aggregation, no cross-pool netting.
- **Source Adapters** (`quota/sources/base.py`, `quota/sources/stub.py`): QuotaSource Protocol + injectable stubs.
- **Tests:** 8 tests (TC-UNIT-101..104, TC-INT-101..104) all passing, ruff/mypy/radon clean.

**UI Rendering:** DEFERRED
- `app/QuotaPanel.swift` gauge rendering requires Phase 01 app shell + Xcode integration (out of scope for iteration 1).
- Acceptance criteria AC-1 and AC-2 remain unchecked until UI is built.

---

## Related

- Task: [`../task-description.md`](../task-description.md) (Problem 2, Desired Solution B)
- Research: `../research/10-claude-p-quota-change.md`, `../research/02-provider-data-availability.md`, `../research/12-two-flow-scheduling-model.md`
