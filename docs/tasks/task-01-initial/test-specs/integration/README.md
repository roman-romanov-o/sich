# Integration Tests

Cover the reliability behaviors E2E can't trigger deterministically — missed/late signals, source assembly, confidence propagation. Run against the component directly with recorded fixtures (no live agent, no live provider endpoints).

## Contents

| Spec | Stories | Priority | Key cases |
|------|---------|----------|-----------|
| [agent-state-detection.md](agent-state-detection.md) | US-004 | Critical | hook→state path, dropped-hook reconciliation, ambiguous→unknown, rapid-transition coalescing |
| [quota-pool-aggregation.md](quota-pool-aggregation.md) | US-006 | High | independent Anthropic pools, confidence flag, absent→unknown, exhaustion semantics |
