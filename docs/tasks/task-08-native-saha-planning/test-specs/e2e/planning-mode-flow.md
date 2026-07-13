# E2E Test Spec: Planning Mode — stepper, doc viewer, driven terminal

**Related Stories:** US-003, US-004, US-005
**Priority:** Critical
**Status:** Draft

## Overview

The core Planning Mode experience: entering the altitude, seeing a live stepper, reading a rendered doc, and having a step-click pre-type a command into the embedded terminal. All interaction ACs (entering/exiting the altitude, clicking a step, the "unsent in terminal line" behavior) must be driven by real `NSEvent` dispatch, not direct handler calls — this project has been burned three times by exactly that shortcut (see interaction-AC-binding-rule memory).

## Preconditions

- A `BoardCard` already bound to a temp `docs/tasks/task-XX/` folder (reuse TC-E2E-002's setup or a shared fixture)
- That folder has a realistic README progress table + at least one artifact with a `**Status:**` marker
- `SessionRegistry`/`PoolFirewall` available in the test harness exactly as used elsewhere (no bypass)

## Test Cases

### TC-E2E-010: Enter Planning Mode shows correct initial stepper state

**Description:** Opening Planning Mode on a bound card renders the stepper matching the folder's real marker state.

**Steps:**
1. Seed folder: Research=Done, Task Description=Done, User Stories=Done, rest=Pending (mirrors this very task's real state)
2. Dispatch the real gesture/click that opens Planning Mode from the card
3. Read the rendered stepper state

**Expected Results:**
- Stepper shows first 3 steps as done, "Design Decisions" as the next/highlighted incomplete step
- This matches `PlanningStateReader`'s parse of the same folder (cross-check, not just UI-blind assertion)
- The Planning Mode terminal appears in `SessionRegistry`'s session list via the same registration path used by drill-in (US-004 AC2) — assert this directly, not just "harness has no bypass" as a precondition
- No `claude -p` process was spawned to produce this terminal (pool-firewall invariant)

---

### TC-E2E-011: Live file change updates the stepper without polling faster than file-watch cadence

**Description:** A `/saha:*`-style external edit to the folder while Planning Mode is open updates the stepper live.

**Steps:**
1. With Planning Mode open (TC-E2E-010 state), externally rewrite the README table to mark "Design Decisions" Done
2. Wait up to the existing `FileWatcher` cadence (sub-250ms) — no more

**Expected Results:**
- Stepper updates to reflect the new state within that window
- No new independent timer/poll loop was introduced (verified via harness instrumentation or code inspection note)

---

### TC-E2E-012: Clicking next incomplete step pre-types the command and selects its doc

**Description:** The core "suggest, not dispatch" interaction (US-004 AC3).

**Steps:**
1. From TC-E2E-010's state, dispatch a real click on the highlighted "Design Decisions" step (the next incomplete one)
2. Read the terminal pane's current input line (not its output/scrollback) and the doc viewer's selected artifact

**Expected Results:**
- The terminal's input line now contains `/saha:decide` (from US-003's step→command table)
- No newline/Enter was sent — the underlying PTY has NOT executed anything (no new process activity, no scrollback change)
- The doc viewer pane now shows `design-decisions/` content (empty/placeholder state is fine since nothing exists yet)

---

### TC-E2E-012b: Clicking an already-done step selects its doc without pre-typing

**Description:** US-004 AC4 — done steps are for review, not for re-running.

**Steps:**
1. From TC-E2E-010's state, dispatch a real click on the "Task Description" step (already Done)
2. Read the terminal's input line and the doc viewer's selected artifact

**Expected Results:**
- The doc viewer pane now shows `task-description.md` content
- The terminal's input line is unchanged (nothing was typed)

---

### TC-E2E-013: Clicking a step while the terminal has unsent input is a no-op with feedback

**Description:** Edge case from US-004 — user was mid-typing something else; per the resolved AC this must not silently overwrite input.

**Steps:**
1. Dispatch real keyDown events typing partial text into the terminal's input line
2. Dispatch a click on the next-incomplete step

**Expected Results:**
- The terminal's input line still contains exactly the partial text typed in step 1 — nothing was appended or overwritten
- A visible feedback signal (highlight/toast) was shown indicating the pre-type was skipped

---

### TC-E2E-014: Back gesture returns to board, same mechanics as drill-in

**Description:** Exiting Planning Mode.

**Steps:**
1. From Planning Mode, dispatch the existing back gesture (`⌘[` / back pill click — real event)

**Expected Results:**
- Board altitude is shown again, Planning Mode overlay is hidden
- The terminal session remains registered (not torn down) exactly as drill-in leaves sessions running

---

### TC-E2E-015: Doc viewer renders the current step's real artifact

**Description:** US-005 — content correctness for a real saha markdown doc (this task's own `task-description.md` is good fixture material: it has tables and checkboxes).

**Steps:**
1. Point the doc viewer pane at a fixture doc with a table, task-list checkboxes, and a header hierarchy
2. Render

**Expected Results:**
- Table renders as a table (not raw pipe text)
- `- [ ]` / `- [x]` render as ☐ / ☑ glyphs
- Headers are visually distinguished per `BoardTheme` tokens
- **Pixel-level fidelity of this rendering is a `needs_human_visual` AC** — this test asserts structural/content correctness (right glyphs, right text extracted, right attributed-string ranges), not final pixel appearance. Capture a screenshot artifact for human sign-off per this project's established pattern (see unfaithful-capture-and-render-path-fix memory: layer-backed custom drawing, not stock control caching, is the once-bitten lesson here for anything visual).

---

### TC-E2E-016: Mermaid block degrades gracefully without `mmdc`

**Description:** US-005 edge case.

**Steps:**
1. Render a fixture doc containing a mermaid code fence, with the harness's `mmdc` lookup forced to "not found"

**Expected Results:**
- The block renders as a syntax-highlighted code block with an install hint
- No exception/crash, rest of the doc still renders

## Cleanup

- Tear down any registered terminal sessions created during the test (respect the one-reader-per-fd invariant — don't leave a session undrained)
