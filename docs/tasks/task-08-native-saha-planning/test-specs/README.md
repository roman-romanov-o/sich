# Test Specifications

Test specs organized by type.

## Coverage Summary

| Type | Specs | Test Cases | Stories Covered |
|------|-------|------------|-----------------|
| E2E | 2 | 16 | US-001, US-002, US-003, US-004, US-005 |
| Integration | 3 | 8 | US-001, US-003, US-006 |
| Unit | 2 | 11 | US-003, US-005 |

## Test Coverage Matrix

| Story | E2E | Integration | Unit | E2E Gap Reason |
|-------|-----|--------------|------|-----------------|
| US-001 | TC-E2E-001, TC-E2E-001b, TC-E2E-003, TC-E2E-006, TC-E2E-007 | TC-INT-001, TC-INT-002, TC-INT-003 | - | - |
| US-002 | TC-E2E-002, TC-E2E-004, TC-E2E-005, TC-E2E-008 | - | - | - |
| US-003 | TC-E2E-010, TC-E2E-011 | TC-INT-010, TC-INT-011, TC-INT-012 | TC-UNIT-001..006 | - |
| US-004 | TC-E2E-012, TC-E2E-012b, TC-E2E-013, TC-E2E-014 | - | - | - |
| US-005 | TC-E2E-015, TC-E2E-016 | - | TC-UNIT-010..015 | - |
| US-006 | - | TC-INT-020, TC-INT-021, TC-INT-022 | - | Pure CLI/JSON contract on the sahaidachny (Python) side — no UI to drive E2E from; integration (pytest against real `TaskVerifier`) is the top of that story's own pyramid. |

## Contents

### E2E Tests
- [card-creation-flow.md](e2e/card-creation-flow.md)
- [planning-mode-flow.md](e2e/planning-mode-flow.md)

### Integration Tests
- [init-task-invocation.md](integration/init-task-invocation.md)
- [planning-state-file-watch.md](integration/planning-state-file-watch.md)
- [saha-plan-status-json.md](integration/saha-plan-status-json.md)

### Unit Tests
- [planning-marker-parser.md](unit/planning-marker-parser.md)
- [markdown-walker.md](unit/markdown-walker.md)
