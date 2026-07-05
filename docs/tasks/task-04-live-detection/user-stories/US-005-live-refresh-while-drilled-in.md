# US-005: Board stays live while drilled into a terminal

**Priority:** Should Have
**Status:** Ready
**Persona:** Operator
**Estimated Complexity:** S

## User Story

As an **operator focused inside one session's terminal**,
I want **the board behind it to keep updating**,
So that **when I return, the columns already reflect reality instead of a frozen snapshot**.

## Acceptance Criteria

1. **Given** a terminal is focused (drill-in, `focusedCardID != nil`)
   **When** agent state changes for any session
   **Then** `applySessions` still re-renders the board — the drill-in refresh suppression at `BoardShell.swift:497` is removed.

## Edge Cases

1. **Rapid focus/blur**
   - Trigger: operator drills in and out quickly.
   - Expected: no flicker, no dropped update, no state regression.

2. **State change for the focused card itself**
   - Trigger: the drilled-in session changes state.
   - Expected: reflected on return (and in any always-visible attention badge) without waiting for blur.

## Technical Notes

Remove the `focusedCardID != nil` early-return in `BoardShell.applySessions` (`:495`); ensure background re-render doesn't disturb the focused terminal surface.

## Dependencies

- **Requires:** none (small, independent).
- **Enables:** correct attention count while drilled in.

## Related

- Task: `../task-description.md` (Success Criterion 6)
