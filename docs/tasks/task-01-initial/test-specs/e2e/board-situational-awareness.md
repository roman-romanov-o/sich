# E2E Test Spec: Board Situational Awareness

**Related Stories:** US-003, US-004, US-005, US-002
**Priority:** Critical
**Status:** Draft

## Overview

The core mission-control loop: multiple sessions appear as cards placed by state, the board reflects real state transitions, the "who needs me" count surfaces blockers, and the operator drills into a session's terminal. This is the product's headline flow.

## Harness note

- **Native macOS app (DD-001, Swift/AppKit) → UI driven via XCUITest** (or equivalent). Exact framework is an implementation-plan decision; this spec is behavior-level.
- **No real paid `claude`.** A **fake-agent fixture** drives every session: a scripted process that (a) renders to the embedded PTY and (b) emits the same Claude Code hook events / JSONL lines a real run would. This keeps E2E deterministic and honors the never-spend-the-pool constraint (the test suite itself must not burn quota or call `claude -p`).

## Preconditions

- App running; embedded terminal substrate available (US-001 green).
- Fake-agent fixture installed, able to replay recorded transition scripts.
- Three fake sessions seeded in distinct project dirs, all `idle`.

## Test Cases

### TC-E2E-001: Sessions appear as cards placed by state (happy path)

**Description:** Seeded sessions render as one card each, in the correct state column. (US-003)

**Steps:**
1. Launch the app with 3 fake sessions (projA, projB, projC), all `idle`.
2. Open the board.
3. Drive projA's fixture: `idle → running`.
4. Drive projB's fixture: `idle → running → waiting-for-input`.

**Expected Results:**
- Exactly 3 cards, no duplicates.
- projA card in `running`; projB in `waiting-for-input`; projC in `idle`.
- Each card shows project dir, agent (Claude), flow tag (B), current state.
- Column moves happen within a few seconds of the driven transition, no manual refresh.

**Test Data:**
```json
{ "sessions": [
  {"id":"projA","dir":"~/proj-a","script":["running"]},
  {"id":"projB","dir":"~/proj-b","script":["running","waiting-for-input"]},
  {"id":"projC","dir":"~/proj-c","script":[]}
] }
```

---

### TC-E2E-002: "Who needs me" count reflects blockers (happy path)

**Description:** The attention count equals the number of waiting/blocked sessions and navigates to them. (US-005)

**Steps:**
1. From TC-E2E-001 end state (projB waiting), read the attention indicator.
2. Drive projA: `running → blocked`.
3. Activate the attention indicator.
4. Resolve both: drive projA `blocked → running` and projB `waiting-for-input → running`; read the indicator.

**Expected Results:**
- Indicator reads `1` after step 1, `2` after step 2.
- Activating it filters/navigates to exactly {projA, projB}.
- projC (idle) is never counted.
- After step 4 (all sessions running/idle), the indicator reads exactly `0` and the panel shows the quiet / no-alarm state — **no false alarm** (US-005 AC#3).

---

### TC-E2E-003: Drill into a session's live terminal (happy path)

**Description:** Clicking a card focuses its embedded terminal, ready for input. (US-002)

**Steps:**
1. Click projB's `waiting-for-input` card.
2. Observe the terminal pane.
3. Return to the board.

**Expected Results:**
- projB's live embedded terminal is focused and shows its scrollback (the prompt it's waiting on).
- Focus transition < 500 ms.
- Returning to the board preserves state and shows any transitions that occurred meanwhile.

---

### TC-E2E-004: Ambiguous signal shows `unknown`, not a wrong state (error path)

**Description:** When the fixture withholds a clean signal, the card degrades to `unknown`/stale rather than guessing. (US-004 AC#3, edge case)

**Steps:**
1. Drive projC into `running`, then have the fixture go silent (no further hooks, no PTY output) past the stale threshold.

**Expected Results:**
- projC card transitions to `unknown`/stale (explicitly marked), **not** left confidently in `running` or guessed into `done`.

---

### TC-E2E-005: Session exits — card does not go stale (error path)

**Description:** A session process ending is reflected, not left hanging. (US-002/US-003 edge cases)

**Steps:**
1. Drive projA's fake process to exit (clean) while its card is `running`.

**Expected Results:**
- projA card moves to `done` (clean exit) within the detection window.
- Clicking it shows final scrollback read-only with a "session ended" affordance and a human-initiated relaunch option (no auto-relaunch).

---

### TC-E2E-006: Zombie session — card goes stale on timeout (error path)

**Description:** A session whose process dies **without any clean exit signal** (no `stop` hook, no exit code reaped) must flip to `stale` after a timeout — distinct from TC-E2E-005's *clean* exit (`done`) and from TC-E2E-004's *ambiguous-signal* `unknown`. (US-003 edge case #2)

**Steps:**
1. Drive projC into `running`.
2. Hard-kill the fake process at the OS level so no exit signal or hook is delivered and the PTY simply stops.
3. Wait past the stale threshold.

**Expected Results:**
- projC's card is explicitly marked `stale` after the timeout (not left in `running`, not silently `done`).
- This is the board-level zombie-reaping path; contrast with TC-E2E-104 (abrupt kill *with* a detectable exit → `blocked`/`done`-with-error).

---

### TC-E2E-007: Drill-in stays responsive at product scale (7 sessions)

**Description:** The product premise is 6–7 parallel sessions; switching between them must stay responsive at that load. (US-002 edge case #2)

**Steps:**
1. Seed **7** fake sessions in distinct dirs, mixed states.
2. Rapidly drill into 5 different cards in succession.

**Expected Results:**
- Each drill-in focuses the correct session's terminal in < 500 ms (the US-002 AC#3 bound holds at scale, not just with 3 sessions).
- Only the focused terminal needs foreground rendering; the board stays responsive.

## Cleanup

- Tear down fake-agent fixtures; clear seeded sessions and board state.
