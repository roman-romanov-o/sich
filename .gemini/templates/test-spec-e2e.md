# E2E Test Spec: {{flow_name}}

**Related Stories:** {{story_ids}}
**Priority:** Critical | High | Medium | Low
**Status:** Draft | Ready | Implemented

## Overview

{{what_user_flow_this_tests}}

## Preconditions

- {{system_state_before_test}}
- {{required_test_data}}
- {{user_authentication_state}}

## Test Cases

### TC-E2E-001: {{happy_path_name}}

**Description:** {{what_this_tests}}

**Steps:**
1. {{user_action_1}}
2. {{user_action_2}}
3. {{user_action_3}}

**Expected Results:**
- {{observable_outcome_1}}
- {{system_state_change}}
- {{ui_feedback}}

**Test Data:**
```json
{
  "input": {
    "{{field}}": "{{value}}"
  },
  "expected": {
    "{{field}}": "{{value}}"
  }
}
```

---

### TC-E2E-002: {{error_scenario_name}}

**Description:** {{what_error_case_this_tests}}

**Steps:**
1. {{action_that_triggers_error}}

**Expected Results:**
- {{error_message_shown}}
- {{system_remains_valid}}

**Test Data:**
```json
{
  "input": {
    "{{field}}": "{{invalid_value}}"
  },
  "expectedError": "{{error_message}}"
}
```

---

### TC-E2E-003: {{edge_case_name}}

**Description:** {{edge_case_description}}

**Steps:**
1. {{step_1}}
2. {{step_2}}

**Expected Results:**
- {{expected_behavior}}

## Test Environment

- **Browser:** Chrome, Firefox, Safari
- **Viewport:** Desktop (1920x1080), Mobile (375x667)
- **Auth State:** {{authenticated_user_type}}

## Cleanup

- {{how_to_reset_state}}
- {{data_to_delete}}

## Automation Notes

```javascript
// Playwright/Cypress selector hints
const selectors = {
  {{element}}: '[data-testid="{{testid}}"]',
  {{element_2}}: '[data-testid="{{testid_2}}"]'
};
```

## Related

- **Stories:** {{story_ids}}
- **Code Change:** {{code_change}}
