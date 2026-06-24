# US-005: "Who needs me" attention signal

**Priority:** Must Have
**Persona:** Operator
**Status:** In Progress (Logic/Derivation Implemented; UI Deferred)
**Estimated Complexity:** S

## User Story

As an **Operator**,
I want a **always-visible "N sessions waiting on you" indicator**,
So that **I never forget a project that's blocked waiting for my input**.

## Acceptance Criteria

1. **Given** K sessions are in `waiting-for-input` or `blocked`,
   **When** I look at the board (or its menubar/summary surface),
   **Then** I see the count K prominently, and it updates live as states change.
   - [x] *Iteration 3: attention_count derivation + attention_cards list fully implemented and tested (no false alarms, exact count verified).*

2. **Given** the attention count is > 0,
   **When** I activate the indicator,
   **Then** I am taken to (or the board filters to) the waiting/blocked cards, so I can clear them in order.
   - [ ] *Deferred: UI navigation/filtering logic gated on Swift/AppKit board shell.*

3. **Given** all sessions are running or idle,
   **When** nothing needs me,
   **Then** the indicator reads zero/quiet (no false alarms).
   - [x] *Iteration 3: Tested via fake-agent E2E (TC-E2E-002); reads exactly 0 when all running/idle.*

## Edge Cases

1. **A session has been waiting a long time**
   - Trigger: `waiting-for-input` persists past a threshold.
   - Expected behavior: optional escalation (e.g. age badge) so the oldest blocker is obvious — but **no auto-response** (suggest/notify only, never type for the user).

2. **Notification vs. ambient count**
   - Trigger: a session newly enters waiting while the app is backgrounded.
   - Expected behavior: ambient count always accurate; active push notification is a separate, opt-in concern (not required for v1 correctness).

## Technical Notes

- Pure derivation over US-004 state. The value is attention-routing, the #1 cognitive-overhead reducer (task-description Problem 1).
- Must honor the suggest-only constraint: this signal *routes attention*, it never acts.

## Dependencies

- **Requires:** US-004 (state), US-003 (board).
- **Enables:** the throughput claim (manage more parallel projects without dropping balls).

## Questions

- [ ] Where does the count live — board header, macOS menubar, or both?

## Implementation Status (Iteration 3)

**Pure derivation logic implemented and fully tested; UI placement/navigation deferred to Swift app shell.**

- **Completed:** attention_count and attention_cards derivations (`src/mission_control/board/attention.py`), fake-agent fixture, logic-level E2E test (TC-E2E-002).
- **Test coverage:** Verified exact count and zero-false-alarm behavior; 50+ integration tests passing (no quota).
- **Deferred:** Board header/menubar UI placement (DD-004 topology decision), filter/navigation interaction on count activation, optional age badge (marked optional in story).
- **Next:** Swift board UI binds to attention_count observable; count updates live as SessionRegistry state changes.

## Related

- Task: [`../task-description.md`](../task-description.md) (Problem 1 — "you have N projects waiting on you")
- Research: `../research/12-two-flow-scheduling-model.md` (the immediate scheduler)
