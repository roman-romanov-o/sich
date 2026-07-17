# Phase {{phase_number}}: {{phase_name}}

**Status:** {{status}}
**Estimated Effort:** S | M | L | XL
**Dependencies:** {{previous_phase}}

<!-- Status values (aligns with execution loop):
  - Not Started: Phase hasn't begun
  - Implementation: Code is being written
  - Test Critique: Tests are being analyzed for quality
  - QA Verification: Acceptance criteria being verified
  - Code Quality: Linting and type checking in progress
  - Blocked: Phase is blocked by an issue
  - Complete: All steps verified and done
-->

## Execution Progress

<!-- Updated automatically by the execution loop -->

| Stage | Status | Last Updated | Notes |
|-------|--------|--------------|-------|
| Implementation | ⏳ Pending | - | - |
| Test Critique | ⏳ Pending | - | - |
| QA Verification | ⏳ Pending | - | - |
| Code Quality | ⏳ Pending | - | - |
| DoD Check | ⏳ Pending | - | - |

<!--
Status indicators:
- ⏳ Pending: Not yet started
- 🔄 In Progress: Currently running
- ✅ Passed: Successfully completed
- ❌ Failed: Failed, needs retry
- ⏭️ Skipped: Skipped (not applicable)
-->

## Objective

{{what_this_phase_accomplishes}}

## Scope

### Stories Included

| Story | Priority | Complexity | Status |
|-------|----------|------------|--------|
| {{story_id_1}} | Must Have | {{complexity}} | [ ] |
| {{story_id_2}} | Must Have | {{complexity}} | [ ] |
| {{story_id_3}} | Should Have | {{complexity}} | [ ] |

### Out of Scope (Deferred)

- {{deferred_story}} (Phase {{later_phase}})

## Implementation Steps

### Step 1: {{component_name}}

**Description:** {{what_to_build}}

**Files to Create/Modify:**
- `{{new_file_path}}` - {{purpose}}
- `{{existing_file_path}}` - {{what_changes}}

**Technical Notes:**
- {{implementation_guidance}}
- {{patterns_to_follow}}

**Acceptance Criteria:**
- [ ] {{verifiable_outcome_1}}
- [ ] {{verifiable_outcome_2}}

**Tests:**
- {{test_case_id_1}}
- {{test_case_id_2}}

---

### Step 2: {{component_name_2}}

**Description:** {{what_to_build_2}}

**Files to Create/Modify:**
- `{{file_path}}` - {{purpose}}

**Technical Notes:**
- {{guidance}}

**Acceptance Criteria:**
- [ ] {{outcome}}

**Tests:**
- {{test_case_id}}

---

### Step 3: {{component_name_3}}

**Description:** {{what_to_build_3}}

**Files to Create/Modify:**
- `{{file_path}}` - {{purpose}}

**Technical Notes:**
- {{guidance}}

**Acceptance Criteria:**
- [ ] {{outcome}}

**Tests:**
- {{test_case_id}}

## Definition of Done

Phase is complete when ALL of the following are true:

### Implementation
- [ ] All stories implemented
- [ ] All code compiles/parses without errors

### Testing
- [ ] All tests written
- [ ] Test quality score: A, B, or C (not D or F)
- [ ] All tests passing

### Quality
- [ ] Ruff: No blocking linting issues
- [ ] ty: No type errors in changed code
- [ ] Complexity: No functions > 20 cognitive complexity

### Documentation
- [ ] Code comments where non-obvious
- [ ] API docs updated (if applicable)

### Verification
- [ ] All acceptance criteria verified by QA agent
- [ ] DoD agent confirms phase complete

## Iteration History

<!-- This section is updated by the execution loop -->

| Iteration | Started | Completed | Result | Fix Info |
|-----------|---------|-----------|--------|----------|
| - | - | - | - | Not yet executed |

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| {{risk_1}} | Low/Medium/High | Low/Medium/High | {{mitigation}} |
| {{risk_2}} | Low/Medium/High | Low/Medium/High | {{mitigation}} |

## Rollback Plan

If issues arise:
1. {{rollback_step_1}}
2. {{rollback_step_2}}

## Notes

{{additional_context}}

## Related

- **Stories:** {{story_ids}}
- **Decisions:** {{decision_ids}}
- **Contracts:** {{code_changes}}
- **Tests:** {{test_specs}}
