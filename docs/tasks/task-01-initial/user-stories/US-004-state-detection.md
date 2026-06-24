# US-004: Trustworthy auto-detected session state

**Priority:** Must Have
**Status:** Detection Logic Done; Card UI Pending (Phase 00/01)
**Persona:** Operator
**Estimated Complexity:** L

## User Story

As an **Operator**,
I want **each card to reflect the session's real state, detected automatically**,
So that **the board is trustworthy and I don't have to open a terminal just to learn what state it's in**.

## Acceptance Criteria

1. **Given** a Claude Code session running in the app,
   **When** the agent transitions (starts running / asks for input / finishes / errors),
   **Then** the app detects it from Claude Code hooks (and/or JSONL tail / PTY signals) and updates the card's state accordingly.

2. **Given** a session is waiting for human input (permission prompt or question),
   **When** that state is reached,
   **Then** the card shows `waiting-for-input` and feeds the US-005 attention count.

3. **Given** the app cannot positively determine a state,
   **When** signals are ambiguous or absent,
   **Then** the card shows an explicit `unknown`/stale indicator rather than guessing a wrong state.

## Edge Cases

1. **Hook delivery gap**
   - Trigger: a hook event is missed or arrives late.
   - Expected behavior: PTY/JSONL fallback reconciles state; the card self-corrects on the next reliable signal rather than locking into a wrong state.

2. **Rapid transitions**
   - Trigger: running → waiting → running within a second.
   - Expected behavior: the final state is shown; no flicker storms or dropped transitions.

## Technical Notes

- v1 = **Claude Code only** (HIGH-confidence signals: HTTP hooks + JSONL — `research/06`). Codex/Gemini detection deferred (separate later story).
- This is the **critical feasibility story** (task-description Research Question 2): the board is useless if state detection is unreliable. Confidence/`unknown` handling is a first-class requirement, not an afterthought.

## Dependencies

- **Requires:** US-001 (sessions run in-app so PTY is readable).
- **Enables:** US-003 (column placement), US-005 (attention count).

## Questions

- [x] Primary signal = hooks, with JSONL/PTY as reconciliation — confirm precedence order. ✓ Verified via TC-INT-001..004.

## Implementation Status (Iteration 2)

The **detection logic layer** is fully implemented and tested:
- **Hook ingestion + normalization:** `detector/HookReceiver` and `SignalEvent` models (Pydantic V2) normalize hook payloads into typed events.
- **State classifier:** Pure function `classify(prior, event) → state` handles all combinations; ambiguous/contradictory cases deterministically → `unknown` (never a wrong guess).
- **Reconciliation + registry:** `StateReconciler` orchestrates hooks + JSONL tail + PTY signals with explicit precedence; detects staleness via injected-clock thresholds; writes final state to `SessionRegistry`.
- **Test coverage:** 43 tests green (TC-INT-001, TC-INT-002, TC-INT-003, TC-INT-004 + TC-UNIT-001, TC-UNIT-002, TC-UNIT-003 + parametrized cases); ruff/mypy/complexipy clean.
- **Deferred to Phase 00/01 (app shell):** Live HTTP hook endpoint integration (app → Python sidecar), PTY read wiring, and card UI rendering. Once the shell exists, the live-wiring is a thin async handler (~50 LOC); state is already observable by Phase 03.

## Related

- Task: [`../task-description.md`](../task-description.md) (Problem 1, Research Question 2)
- Research: `../research/06-agent-state-detection.md`
