# Integration Test Spec: `saha plan-status --json` (sahaidachny repo, pytest)

**Related:** US-006
**Priority:** High
**Status:** Draft

## Overview

Note: this spec targets the **sahaidachny** repo, not this app — it's Python/pytest per that repo's own testing philosophy (functional pytest, integration-first, fixtures/parametrization), invoked from `saha/commands/execution.py` wrapping `saha/verification/checker.py::TaskVerifier`.

## Dependencies

- Real `TaskVerifier` against real temp task folders (no mocking the verifier itself — it's the thing under test)

## Test Cases

### TC-INT-020: Partially-complete task folder returns correct JSON shape and next_step

**Description:** Core contract test (US-006 AC1/AC3).

**Setup:**
```python
@pytest.fixture
def partial_task_folder(tmp_path):
    # README with Research/Task Description/User Stories = Done, rest Pending
    ...
```

**Input:**
```json
{ "cli": "saha plan-status task-01-partial --json" }
```

**Expected Output:**
```json
{
  "task_id": "task-01-partial",
  "checks": [ {"name": "task_description", "status": "passed"}, "..." ],
  "next_step": "design_decisions",
  "complete": false
}
```

**Assertions:**
- stdout is valid JSON, parses without error
- `next_step` matches the first check with status != passed
- Exit code 0

---

### TC-INT-021: Fully-complete task folder has null next_step

**Description:** US-006 AC2.

**Expected Output:**
```json
{ "next_step": null, "complete": true }
```

---

### TC-INT-022: Unresolvable task-id errors cleanly

**Description:** US-006 edge case.

**Input:**
```json
{ "cli": "saha plan-status nonexistent-task --json" }
```

**Expected Output:**
- Non-zero exit code
- Clear error message on stderr
- **Nothing** on stdout (no partial/malformed JSON emitted)

## Data Fixtures

```python
@pytest.fixture
def complete_task_folder(tmp_path):
    ...

@pytest.fixture
def partial_task_folder(tmp_path):
    ...
```
