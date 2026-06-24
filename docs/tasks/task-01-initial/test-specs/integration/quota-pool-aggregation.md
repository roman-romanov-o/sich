# Integration Test Spec: Quota Pool Aggregation

**Related:** US-006
**Priority:** High
**Status:** Draft

## Overview

The component that assembles the multi-pool quota model from heterogeneous sources (interactive window math, Agent SDK credit balance, Codex/Gemini usage) into the gauge model the UI renders. E2E checks the *rendering*; this checks the *assembly*: source-missing handling, confidence propagation, and pool independence.

## Dependencies

- The quota-aggregation component under test.
- Stub sources returning fixture values (precise + inferred + absent), injectable per case.

## Test Cases

### TC-INT-101: Both Anthropic pools assembled independently

**Description:** Interactive and Agent SDK credit are produced as separate, non-fungible gauges. (US-006 AC#1)

**Input:** interactive window+weekly source values; Agent SDK credit balance.

**Expected Output:** two distinct pool models; no arithmetic that nets one against the other.

**Assertions:**
- Draining interactive does not change Agent SDK remaining and vice-versa.

---

### TC-INT-102: Inferred source carries a confidence flag

**Description:** Window-math-derived interactive remaining is marked inferred end-to-end. (US-006 AC#3)

**Input:** interactive source flagged `inferred=true`; Agent SDK source `inferred=false`.

**Expected Output:** interactive gauge `confidence=estimated`; Agent SDK `confidence=measured`.

---

### TC-INT-103: Absent source → "unknown", not zero and not full

**Description:** A provider with no usable signal is represented as unknown. (US-006 edge case #2)

**Input:** Gemini source returns no data.

**Expected Output:** Gemini gauge `state=unknown` (neither `remaining=0` nor `remaining=100%`).

---

### TC-INT-104: Exhausted states distinguished by refill semantics

**Description:** Hard-stop (Agent SDK) vs. window-reset (interactive) exhaustion are modeled differently. (US-006 edge case #1)

**Input:** Agent SDK credit = 0; interactive window = locked.

**Expected Output:** Agent SDK `exhausted, refill=monthly, fallback=none`; interactive `exhausted, resets=window`.

**Assertions:**
- The model preserves the distinction the UI needs to warn correctly.

## Data Fixtures

```python
@pytest.fixture
def quota_sources():
    # precise Agent SDK credit, inferred interactive window, absent Gemini
    return { ... }
```

> Harness note: fixture shown in pytest form per repo convention; actual harness language follows the implementation-plan stack decision (the quota layer may be a separate daemon). Behavior is language-neutral.
