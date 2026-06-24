# Integration Test Spec: Agent State Detection

**Related:** US-004 (supports US-003, US-005)
**Priority:** Critical
**Status:** Draft

## Overview

The state-detection layer that turns Claude Code signals (hooks, JSONL tail, PTY) into a card state. E2E can drive the *happy* transitions, but the **reliability behaviors** — missed/late hook reconciliation, signal precedence, ambiguous→`unknown` — are hard to trigger deterministically end-to-end, so they are covered here against the detector component directly.

## Dependencies

- The state-detection component under test (consumes a stream of hook events + a JSONL source + PTY signal).
- Recorded fixture sequences of Claude Code hook payloads / JSONL lines (real shapes, captured once; no live agent).

## Test Cases

### TC-INT-001: Hook events drive the correct state transitions

**Description:** A canonical hook sequence yields the expected state path. (US-004 AC#1)

**Setup:** feed the detector a recorded sequence: session-start → tool-use → permission-request → tool-use → stop.

**Expected Output:** state path `running → running → waiting-for-input → running → done`.

**Assertions:**
- Each transition emitted once, in order.
- `waiting-for-input` is entered exactly on the permission-request event.

---

### TC-INT-002: Missed/late hook is reconciled by JSONL/PTY fallback

**Description:** When a hook is dropped, the detector self-corrects from the next reliable signal rather than locking a wrong state. (US-004 edge case #1)

**Setup:** feed a sequence with the `stop` hook omitted, but the JSONL shows the turn completed.

**Expected Output:** state converges to `done` via JSONL reconciliation within the reconciliation window.

**Assertions:**
- Detector does not remain stuck in `running` indefinitely.
- No wrong terminal state (`blocked`) is emitted from the gap alone.

---

### TC-INT-003: Ambiguous/absent signals yield `unknown`, not a guess

**Description:** With contradictory or missing signals, the detector reports `unknown`/stale. (US-004 AC#3)

**Setup:** feed `running` then silence beyond the stale threshold (no hooks, no PTY, no JSONL growth).

**Expected Output:** `unknown`/stale.

**Assertions:**
- State is explicitly `unknown`, never silently `running` or invented `done`.

---

### TC-INT-004: Rapid transitions settle on the final state

**Description:** running→waiting→running within one second does not flicker or drop. (US-004 edge case #2)

**Setup:** feed three transitions with sub-second spacing.

**Expected Output:** final state `running`; intermediate states coalesced (no transition storm to the board).

**Assertions:**
- At most a bounded number of emitted updates; final state correct.

## Data Fixtures

```text
fixtures/claude_hooks/normal_turn.jsonl        # session-start..stop
fixtures/claude_hooks/dropped_stop.jsonl       # stop hook omitted; JSONL completes
fixtures/claude_hooks/silent_after_running.jsonl
fixtures/claude_hooks/rapid_transitions.jsonl
```
