# Unit Test Spec: {{module_name}}

**File:** `{{source_file_path}}`
**Priority:** High | Medium | Low
**Status:** Draft | Ready | Implemented

## Overview

{{what_logic_this_tests}}

## Functions Under Test

- `{{function_1}}`
- `{{function_2}}`

## Test Cases

### TC-UNIT-001: {{function_name}} - {{scenario}}

**Input:**
```python
{{function_name}}({{arg1}}, {{arg2}})
```

**Expected:**
```python
{{expected_result}}
```

**Notes:** {{edge_case_or_reason}}

---

### TC-UNIT-002: {{function_name}} - {{edge_case}}

**Input:**
```python
{{function_name}}(None, "")
```

**Expected:**
```python
raises(ValueError, match="{{error_message}}")
```

---

### TC-UNIT-003: {{function_name}} - {{boundary_case}}

**Input:**
```python
{{function_name}}({{boundary_value}})
```

**Expected:**
```python
{{expected_boundary_result}}
```

## Parameterized Cases

### {{function_name}}

| Input | Expected | Description |
|-------|----------|-------------|
| `({{input_1}})` | `{{expected_1}}` | {{description_1}} |
| `({{input_2}})` | `{{expected_2}}` | {{description_2}} |
| `({{input_3}})` | `{{expected_3}}` | {{description_3}} |
| `({{input_4}})` | `raises({{Error}})` | {{error_description}} |

```python
@pytest.mark.parametrize("input_val,expected", [
    ({{input_1}}, {{expected_1}}),
    ({{input_2}}, {{expected_2}}),
    ({{input_3}}, {{expected_3}}),
])
def test_{{function_name}}(input_val, expected):
    assert {{function_name}}(input_val) == expected
```

## Mocks Required

| Mock | Target | Reason |
|------|--------|--------|
| `{{mock_name}}` | `{{module.function}}` | {{why_mocked}} |

```python
@pytest.fixture
def {{mock_name}}(mocker):
    return mocker.patch(
        "{{module_path}}",
        return_value={{mock_return}}
    )
```

## Test Implementation Hints

```python
class Test{{ClassName}}:
    """Tests for {{module_name}}"""

    def test_{{scenario_1}}(self):
        # Arrange
        {{setup}}

        # Act
        result = {{function_call}}

        # Assert
        assert result == {{expected}}

    def test_{{scenario_2}}_raises_on_invalid_input(self):
        with pytest.raises({{ExceptionType}}) as exc_info:
            {{function_call_with_invalid_input}}

        assert "{{expected_message}}" in str(exc_info.value)
```

## Coverage Notes

- {{lines_or_branches_to_cover}}
- {{specific_conditions_to_test}}

## Related

- **Stories:** {{story_ids}}
- **Integration Tests:** {{integration_test_specs}}
