---
name: Test Critique
description: |
  Guidance for evaluating test quality and detecting hollow tests.
version: 0.1.0
---

# Test Critique

Use this skill to review tests for quality and signal whether QA should proceed.

## Hollow Test Patterns

- Over-mocking (more than 3 mocks per test)
- Mocking the System Under Test
- Placeholder tests (`pass`, `...`, `assert True`)
- Assertions that only check mock calls, not outcomes

## What Good Looks Like

- Asserts observable behavior, not implementation details
- Uses minimal mocking (only external boundaries)
- Verifies edge cases and error handling

## Output Contract

When requested, return a JSON block:

```json
{
  "critique_passed": true,
  "test_quality_score": "A-F",
  "fix_info": ""
}
```
