# {{story_id}}: {{title}}

**Priority:** Must Have | Should Have | Could Have
**Status:** {{status}}
**Persona:** {{persona}}
**Estimated Complexity:** S | M | L | XL

<!-- Status values:
  - Draft: Story is being written
  - Ready: Story is complete and ready for implementation
  - In Progress: Implementation has started
  - Testing: Tests written, being verified
  - QA Pending: Awaiting QA verification
  - Code Review: Quality checks in progress
  - Done: All acceptance criteria verified
-->

## User Story

As a **{{persona}}**,
I want to **{{action}}**,
So that **{{benefit}}**.

## Acceptance Criteria

Conditions that must be true for this story to be complete:

- [ ] **AC-1:** {{criterion_1}}
- [ ] **AC-2:** {{criterion_2}}
- [ ] **AC-3:** {{criterion_3}}

<!--
Execution Loop Tracking:
When the agentic loop runs, it will update these checkboxes:
- [ ] = pending
- [~] = in progress (being implemented this iteration)
- [x] = done (verified by QA)
-->

## Edge Cases

Scenarios that need explicit handling:

1. **{{edge_case_name}}**
   - Trigger: {{what_causes_this}}
   - Expected behavior: {{what_should_happen}}

2. **{{edge_case_name_2}}**
   - Trigger: {{trigger_2}}
   - Expected behavior: {{behavior_2}}

## Technical Notes

{{technical_considerations}}

## Dependencies

- **Requires:** {{stories_this_depends_on}}
- **Enables:** {{stories_that_depend_on_this}}

## Execution History

<!-- This section is updated by the execution loop -->

| Iteration | Phase | Result | Notes |
|-----------|-------|--------|-------|
| - | - | - | Not yet executed |

<!--
Phase values:
- Implementation: Code was written
- Test Critique: Tests were analyzed for quality
- QA: Acceptance criteria were verified
- Code Quality: Linting and type checking passed
- Manager: Status was updated
- DoD: Completion was verified
-->

## Questions

- [ ] {{open_question}}

## Related

- Task: {{link_to_task_description}}
- Research: {{link_to_research}}
- Design Decision: {{dd_id}}
