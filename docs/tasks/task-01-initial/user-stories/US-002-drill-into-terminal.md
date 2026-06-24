# US-002: Drill from a board card into its live terminal

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator
**Estimated Complexity:** M

## User Story

As an **Operator**,
I want to **click a board card and drop straight into that session's live terminal pane**,
So that **I can act on a session the instant I see it needs me, without hunting through tabs**.

## Acceptance Criteria

1. **Given** the board shows several session cards,
   **When** I click (or keystroke-select) a card,
   **Then** that session's live embedded terminal becomes focused/visible (the mockup's "Terminal for the Task" pane), ready for typed input.

2. **Given** I am focused in a session's terminal,
   **When** I return to the board,
   **Then** the board state is unchanged and reflects any state transition that happened while I was in the terminal.

3. **Given** a card is selected,
   **When** the terminal pane opens,
   **Then** focusing it takes < 500 ms (direct, in-app — not an OS window-activation round-trip).

## Edge Cases

1. **Card whose session has ended**
   - Trigger: clicking a card for a session that exited.
   - Expected behavior: show the final scrollback read-only with a clear "session ended" affordance; offer relaunch (human-initiated), never auto-relaunch.

2. **Many sessions open at once (6–7+)**
   - Trigger: drilling rapidly between cards.
   - Expected behavior: switching terminals stays responsive; only the focused terminal needs to be foreground-rendered.

## Technical Notes

- Direct consequence of **DD-001**: because the app owns the PTY, drill-down is an in-app focus, not an AppleScript `select tab` jump (report 13 Altitude 2 is upgraded from "focus the real Ghostty tab" to "focus our embedded terminal").

## Dependencies

- **Requires:** US-001 (embedded terminal), US-003 (board cards exist).
- **Enables:** the core "see → act" loop of the product.

## Questions

- [ ] Single focused terminal pane vs. split/multi-pane view? (UX detail; defer to design.)

## Related

- Task: [`../task-description.md`](../task-description.md) (Desired Solution A — "jump straight to that tab")
- Research: `../research/14-ui-mockup-critique.md` (the terminal pane), `../research/13-board-view-and-feature-parity.md`
- Design Decision: **DD-001**
