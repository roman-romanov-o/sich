# US-002: Infer task-folder binding for pre-existing cards

**Priority:** Should Have
**Status:** Done (iteration 4)
**Persona:** Kanban app user with cards created before this feature (or outside the app)
**Estimated Complexity:** S

## User Story

As a **kanban app user**,
I want to **have my existing saha-flow cards automatically linked to their task folder**,
So that **I don't lose Planning Mode access just because the card predates the creation-time binding**.

## Acceptance Criteria

1. [x] **Given** a card has no `taskFolder` set
   **When** the app loads the board
   **Then** `TaskFolderIndex` scans the card's projectDir for `docs/tasks/task-*/` and reads `.sahaidachny/current-task` to infer a binding

2. [x] **Given** more than one task folder is found and none matches `current-task`
   **When** inference runs
   **Then** the card is left unbound rather than guessing wrong, and Planning Mode entry prompts the user to pick

## Edge Cases

1. **No task folders found at all**
   - Trigger: projectDir has no `docs/tasks/`
   - Expected behavior: card stays unbound; entering Planning Mode offers the create-new path from US-001

## Technical Notes

Pure logic, `swift test`-able independent of UI.

## Dependencies

- **Requires:** none
- **Enables:** US-003 for cards not created via US-001

## Questions

- [ ] none currently

## Related

- Task: ../task-description.md
- Research: ../research/native-planning-proposal.md
