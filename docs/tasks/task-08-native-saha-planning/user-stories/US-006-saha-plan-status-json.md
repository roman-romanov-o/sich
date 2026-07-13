# US-006: `saha plan-status --json` command

**Priority:** Should Have
**Status:** Draft
**Persona:** Sahaidachny CLI user / consuming UIs (this app, future task-06 advisor)
**Estimated Complexity:** S

## User Story

As a **consumer of saha's planning state (this app, and eventually task-06's advisor)**,
I want to **query planning completeness as structured JSON instead of scraping markdown markers myself**,
So that **planning-state parsing has one official, tested source of truth shared across tools**.

## Acceptance Criteria

1. **Given** a task folder path or task-id
   **When** `saha plan-status <task-id> --json` runs
   **Then** it wraps the existing `TaskVerifier.verify()` and emits its `CheckResult`s plus a derived `next_step` as JSON

2. **Given** the command runs on a task with all steps complete
   **When** JSON is emitted
   **Then** `next_step` is null/absent and overall status reflects completion

3. **Given** the command is covered by pytest
   **When** the test suite runs
   **Then** at least one test exercises a partially-complete task folder and asserts the JSON shape and `next_step` value

## Edge Cases

1. **Task-id doesn't resolve**
   - Trigger: invalid/missing task-id and no `current-task` set
   - Expected behavior: clear error, non-zero exit, no partial JSON on stdout

## Technical Notes

This lives in the sahaidachny repo (`saha/commands/execution.py` or a new command module), reusing `saha/verification/checker.py` as-is. This is the saha-side half of task-08; the app's `PlanningStateReader` (US-003) should prefer this JSON when available and fall back to marker-scraping otherwise.

## Dependencies

- **Requires:** none (existing `TaskVerifier` already returns structured `CheckResult`s)
- **Enables:** US-003's optional fast path

## Questions

- [ ] Hard dependency or always-optional fast path for the app? (open question from task description)

## Related

- Task: ../task-description.md
- Research: ../research/native-planning-proposal.md
