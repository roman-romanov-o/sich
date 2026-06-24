# US-003: See every session as a card placed by state

**Priority:** Must Have
**Status:** In Progress (Logic/Derivation Implemented; Rendering Deferred)
**Persona:** Operator
**Estimated Complexity:** L

## User Story

As an **Operator**,
I want to **see every active agentic-coding session as a card, spatially arranged by its state**,
So that **I grasp the state of everything at a glance instead of serially scanning tabs**.

## Acceptance Criteria

1. **Given** I have N sessions running in the app,
   **When** I open the board,
   **Then** each session appears as exactly one card, placed in a column by state: `idle`, `running`, `waiting-for-input`, `running-tests`, `blocked`, `done`.
   - [x] *Iteration 3: Card model + placement derivation (column_for_state, place) implemented and tested at data level via fake-agent E2E.*

2. **Given** a card,
   **When** I look at it,
   **Then** it shows the cmux-style metadata: working directory / project, agent (Claude/Codex/Gemini), flow type (A autonomous / B interactive), and current state.
   - [x] *Iteration 3: Card model with Agent/Flow enums and metadata fields complete; data-level validation in test suite.*

3. **Given** a session changes state (e.g. starts waiting for input),
   **When** the change is detected (US-004),
   **Then** its card moves to the new column within a few seconds, without manual refresh.
   - [ ] *Rendering/live-move animation deferred to Swift/AppKit board shell (Phase 00/01).*

## Edge Cases

1. **Session the app didn't launch (external)**
   - Trigger: a `claude` session running outside the app (if hybrid observation is in scope — see DD-002).
   - Expected behavior: for v1 (in-app-only assumption), only app-hosted sessions appear; external-session observation is explicitly out of v1 scope until DD-002 is decided.

2. **Stale/zombie card**
   - Trigger: a session whose process died without a clean exit signal.
   - Expected behavior: the card is marked stale (not silently left in `running`) after a timeout.

## Technical Notes

- Board topology (state-columns + flow-tag vs. swimlanes-by-flow) is an **open decision (DD-004)**; this story assumes **state-columns with a flow tag** as the v1 default. Cards carry flow type either way.
- Card metadata schema borrowed from cmux (report 13 Part A).

## Dependencies

- **Requires:** US-004 (state detection feeds the columns).
- **Enables:** US-002 (drill-down), US-005 (who-needs-me count).

## Questions

- [ ] DD-004: state-columns + flow-tag vs. swimlanes-by-flow.

## Implementation Status (Iteration 3)

**Pure derivation logic implemented and fully tested; rendering deferred to Swift app shell.**

- **Completed:** Card data model (`src/mission_control/board/card.py`), placement mapping (`src/mission_control/board/placement.py`), state→column derivation, fake-agent fixture, logic-level E2E tests (TC-E2E-001/002/004).
- **Test coverage:** 50+ integration tests passing (fake-agent driven, no quota spent).
- **Deferred:** Board rendering (Swift/AppKit), live column animation, timeout/zombie detection (gated on Phase 00/01 app shell and process management).
- **Next:** Swift board view consumes Card/placement models; wires state-change signals to live-move animation.

## Related

- Task: [`../task-description.md`](../task-description.md) (Problem 1)
- Research: `../research/13-board-view-and-feature-parity.md`, `../research/12-two-flow-scheduling-model.md`, `../research/14-ui-mockup-critique.md`
