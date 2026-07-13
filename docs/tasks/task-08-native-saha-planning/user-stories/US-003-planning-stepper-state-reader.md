# US-003: Live planning-progress stepper

**Priority:** Must Have
**Status:** Draft
**Persona:** Kanban app user running saha planning
**Estimated Complexity:** M

## User Story

As a **kanban app user**,
I want to **see a live stepper of the saha planning pipeline (research → task → stories → decide → contracts → test-specs → plan → verify) for my bound task folder**,
So that **I always know what's done and what's next without manually reading files or running `/saha:status`**.

## Acceptance Criteria

1. **Given** a card is bound to a task folder
   **When** Planning Mode is opened
   **Then** `PlanningStateReader` scans the folder's `**Status:**` markers and README progress table and renders each step as pending/in-progress/done

2. **Given** a `/saha:*` command writes or updates a doc in the bound folder
   **When** the file-watcher fires
   **Then** the stepper updates within the existing sub-250ms file-watch cadence, with no added polling loop [x] (iteration 5)

3. **Given** saha exposes `plan-status --json` (US-005)
   **When** it is available
   **Then** the reader prefers it as the source of truth over marker-scraping

## Edge Cases

1. **Malformed or missing status markers**
   - Trigger: a doc without a `**Status:**` line
   - Expected behavior: that step shows "unknown", does not crash the reader

2. **`plan-status --json` absent (older saha version)**
   - Trigger: saha CLI doesn't support the flag
   - Expected behavior: silent fallback to marker-scraping, no user-visible error

## Technical Notes

Pure logic in GhostlingCore, fully `swift test`-able: markers in → `PlanningState` out. Reuses the existing `FileWatcher`.

`PlanningState` carries a fixed step → slash-command table, one entry per pipeline step, so US-004 doesn't have to invent it:

| Step | Command |
|---|---|
| Research | `/saha:research` |
| Task Description | `/saha:task` |
| User Stories | `/saha:stories` |
| Design Decisions | `/saha:decide` |
| Code Changes | `/saha:contracts` |
| Test Specs | `/saha:test-specs` |
| Implementation Plan | `/saha:plan` |
| Verify | `/saha:verify` |

## Dependencies

- **Requires:** US-001 or US-002 (a binding must exist)
- **Enables:** US-004, US-006

## Questions

- [ ] Should `plan-status --json` be a hard dependency or always-optional fast path? (open question from task description)

## Related

- Task: ../task-description.md
- Research: ../research/native-planning-proposal.md
