# TASK-02: Estimation

**Status:** Planning
**Mode:** Full
**Created:** 2026-06-17

## Overview

Establish the evidence base and design stance for how the kanban models **task estimation, capacity, and attention** in the AI-assisted era. Core thesis from the research: stop estimating individual items, forecast aggregates probabilistically from observed flow, and treat human review-attention (not agent compute or token quota) as the binding capacity constraint.

## Planning Progress

| Step | Status | Artifacts |
|------|--------|-----------|
| Research | **Complete** | [research/estimation-in-the-ai-era.md](research/estimation-in-the-ai-era.md) |
| Task Description | Pending | task-description.md |
| User Stories | Pending | user-stories/US-*.md |
| Design Decisions | **In progress** | [DD-001](design-decisions/DD-001-effort-attribution-pomodoro-self-report.md), [DD-002](design-decisions/DD-002-pomodoro-integration-coupling.md) (effort-awareness locked; estimation-core stances still open) |
| Code Changes | Pending | code-changes/*.md |
| Test Specs | Pending | test-specs/**/*.md |
| Implementation Plan | Pending | implementation-plan/phase-*.md |

## Next Steps

- [ ] Run `/saha:task` to turn the research recommendations into a task description
- [ ] Run `/saha:decide` to capture the "no-estimates / flow-forecasting / attention-as-WIP" design stances as DDs
