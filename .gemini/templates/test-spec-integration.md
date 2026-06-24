# Integration Test Spec: {{component_name}}

**Related:** {{story_ids}}, {{code_change}}
**Priority:** Critical | High | Medium | Low
**Status:** Draft | Ready | Implemented

## Overview

{{what_integration_this_tests}}

## Dependencies

- {{database_or_service}}
- {{mock_requirements}}

## Test Cases

### TC-INT-001: {{scenario_name}}

**Description:** {{what_this_tests}}

**Setup:**
```python
@pytest.fixture
def {{fixture_name}}():
    return {
        "{{field}}": "{{value}}"
    }
```

**Input:**
```json
{
  "{{field}}": "{{value}}"
}
```

**Expected Output:**
```json
{
  "{{field}}": "{{expected_value}}"
}
```

**Assertions:**
- {{specific_assertion}}
- {{database_state_check}}
- {{side_effect_verification}}

---

### TC-INT-002: {{error_handling_name}}

**Description:** {{error_case_description}}

**Input:**
```json
{
  "{{field}}": "{{invalid_value}}"
}
```

**Expected:**
- Status: {{status_code}}
- Error code: {{error_code}}
- Message contains: "{{error_message}}"

**Assertions:**
- {{no_side_effects}}
- {{database_unchanged}}

---

### TC-INT-003: {{concurrent_scenario}}

**Description:** {{concurrency_test_description}}

**Setup:**
- {{initial_state}}

**Actions:**
1. Request A: {{request_a}}
2. Request B (concurrent): {{request_b}}

**Expected:**
- {{expected_behavior}}
- {{no_race_conditions}}

## Data Fixtures

```python
@pytest.fixture
def {{fixture_name}}(db_session):
    """{{fixture_description}}"""
    entity = {{Entity}}(
        {{field}}="{{value}}"
    )
    db_session.add(entity)
    db_session.commit()
    yield entity
    db_session.delete(entity)
    db_session.commit()
```

## Mocks

```python
@pytest.fixture
def {{mock_name}}(mocker):
    """{{why_mocked}}"""
    return mocker.patch(
        "{{module_path}}",
        return_value={{mock_return_value}}
    )
```

## Database State Verification

```python
def assert_{{entity}}_created(db_session, expected):
    result = db_session.query({{Entity}}).filter_by(
        {{field}}=expected["{{field}}"]
    ).first()
    assert result is not None
    assert result.{{field}} == expected["{{field}}"]
```

## Related

- **Stories:** {{story_ids}}
- **Code Change:** {{code_change}}
- **Unit Tests:** {{unit_test_specs}}
