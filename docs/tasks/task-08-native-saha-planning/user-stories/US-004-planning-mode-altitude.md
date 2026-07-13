# US-004: Planning Mode altitude with driven terminal

**Priority:** Must Have
**Status:** Draft
**Persona:** Kanban app user running saha planning
**Estimated Complexity:** L

## User Story

As a **kanban app user**,
I want to **enter a full-window Planning Mode with a stepper, doc viewer, and a real Claude terminal, where clicking the next step pre-types the right `/saha:*` command**,
So that **I can run the planning pipeline conversationally without memorizing command order or leaving the app**.

## Acceptance Criteria

1. **Given** a bound card
   **When** the user enters Planning Mode
   **Then** `BoardShell` shows a new full-window overlay (sibling to the existing drill-in) with three panes: stepper, doc viewer, terminal [x] (iteration 5)

2. **Given** the terminal pane
   **When** it is created
   **Then** it is a normal `SessionRegistry`-registered session — no new spawn path, no `claude -p`, pool-firewall invariant intact

3. **Given** the user clicks the *next incomplete* step in the stepper
   **When** the click is handled
   **Then** that step's command (from US-003's step→command table) is typed into the terminal's input line, unsent — the user must press Enter themselves — AND that step's doc is selected in the doc viewer pane

4. **Given** the user clicks any *already-done* step (not the next incomplete one)
   **When** the click is handled
   **Then** that step's doc is selected in the doc viewer pane, and nothing is typed into the terminal (no command pre-typing for completed steps)

5. **Given** the user is in Planning Mode
   **When** they trigger the existing back gesture (e.g. `⌘[`)
   **Then** they return to the board, same mechanics as drill-in's `returnToBoard()` [x] (iteration 5)

6. **Given** US-005 (doc rendering) has not landed yet
   **When** Planning Mode is demoed on its own
   **Then** the doc viewer pane may show the raw file text as a placeholder — US-004 is independently demoable without US-005's rendering

## Edge Cases

1. **User clicks a step while the terminal has an in-progress command typed**
   - Trigger: partial input already in the terminal's line buffer
   - Expected behavior: no-op — the step click does nothing to the terminal's input line, and gives visible feedback (e.g. a brief highlight/toast) that the pre-type was skipped because input was already present

## Technical Notes

Reuses `drill()/returnToBoard()`-style overlay hide/show mechanics already proven in `BoardShell`. Suggest-not-dispatch is a hard product invariant (matches task-06's suggest-only rule for the advisor). Step→command mapping is owned by US-003's `PlanningState`, not reinvented here.

## Dependencies

- **Requires:** US-003 (stepper data)
- **Enables:** US-006

## Questions

- [ ] Does pre-typing need an explicit confirm affordance beyond "unsent in the terminal line"? (open question from task description)

## Related

- Task: ../task-description.md
- Research: ../research/native-planning-proposal.md
