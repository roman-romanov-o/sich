# US-001: Create a saha-flow card bound to a task folder

**Priority:** Must Have
**Status:** Done (iteration 4)
**Persona:** Kanban app user planning a saha task
**Estimated Complexity:** M

## User Story

As a **kanban app user**,
I want to **choose the saha flow when creating a card, and pick or create its `docs/tasks/task-XX/` folder right there**,
So that **the card is bound to its planning artifacts from the moment it exists, instead of the two staying disconnected**.

## Acceptance Criteria

1. [x] **Given** the user starts creating a new card
   **When** they reach the flow choice
   **Then** they see saha-flow vs interactive-flow as an explicit choice (mirroring existing `CardFlow.a`/`.b`)

2. [x] **Given** the user picks saha flow
   **When** the picker opens
   **Then** it lists existing `docs/tasks/task-*/` folders in the project with a planning-progress chip (e.g. "5/8"), plus a "create new" option

3. [x] **Given** the user picks "create new" and enters a name
   **When** they confirm
   **Then** the app invokes saha's `init_task.sh` to scaffold the folder (auto-numbered, slugified); `.sahaidachny/current-task` is only used as a hint for cards with no explicit binding (US-002) and is never treated as authoritative once `BoardCard.taskFolder` is set — creating card B must not silently break card A's binding, since `current-task` is a single project-wide pointer

4. [x] **Given** a card is created via either path
   **When** it lands on the board
   **Then** `BoardCard.taskFolder` is set to the bound folder path

## Edge Cases

1. **No `docs/tasks/` folder exists yet**
   - Trigger: brand-new project directory
   - Expected behavior: picker shows only "create new"; picking it works from a clean slate

2. **`init_task.sh` fails or saha isn't installed**
   - Trigger: script missing / non-zero exit
   - Expected behavior: creation flow surfaces the failure and does not silently create an unbound card

3. **Chosen existing folder has no README/status markers**
   - Trigger: a bare/malformed task folder
   - Expected behavior: progress chip shows "unknown"/0, binding still succeeds

## Technical Notes

`BoardCard` gains an optional `taskFolder`. This is the primary binding path; `TaskFolderIndex` (US-002) is the fallback for cards created outside the app.

## Dependencies

- **Requires:** none
- **Enables:** US-002 (fallback still needed for pre-existing cards), US-003, US-006

## Questions

- [ ] none currently

## Related

- Task: ../task-description.md
- Research: ../research/native-planning-proposal.md
