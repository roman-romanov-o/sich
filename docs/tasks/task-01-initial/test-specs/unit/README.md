# Unit Tests

Only for genuinely tricky pure logic (per the testing philosophy — no unit tests for glue/CRUD). Both are pure functions with injected inputs (no I/O, no system clock).

## Contents

| Spec | Stories | Priority | Why a unit test |
|------|---------|----------|-----------------|
| [state-classifier.md](state-classifier.md) | US-004 | High | fiddly signal→state branching incl. ambiguous→unknown; exhaustive fast coverage |
| [interactive-window-math.md](interactive-window-math.md) | US-006 | High | 5h rolling window + weekly cap arithmetic; deterministic with injected clock |
