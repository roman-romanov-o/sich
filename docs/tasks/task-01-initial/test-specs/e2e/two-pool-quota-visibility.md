# E2E Test Spec: Two-Pool Quota Visibility

**Related Stories:** US-006
**Priority:** High
**Status:** Draft

## Overview

The differentiator surface: the quota panel shows **both** Anthropic pools as distinct gauges (interactive vs. Agent SDK credit), plus best-effort Codex/Gemini, with confidence shown for inferred values and clear exhausted/unknown states.

## Harness note

- Drives the native app via XCUITest (or equivalent). Quota **data sources are stubbed** with fixture values (recorded usage signals) — the suite does not hit live provider endpoints and does not spend quota to read it.

## Preconditions

- App running with the quota panel enabled.
- Stubbed quota sources injectable per test (interactive window state, Agent SDK credit balance, Codex/Gemini usage).

## Test Cases

### TC-E2E-201: Both Anthropic pools shown as distinct gauges (happy path)

**Description:** Interactive and Agent SDK credit appear separately, each with remaining + reset. (US-006 AC#1)

**Steps:**
1. Inject: interactive = 40% of 5h window used, weekly 30% used; Agent SDK credit = 60% remaining.
2. Open the quota panel.

**Expected Results:**
- Two clearly-labeled Anthropic gauges: **interactive** (window % + weekly % + window reset time) and **Agent SDK credit** (remaining + monthly refill).
- The two are not merged into a single number (they don't fungibly trade).

**Test Data:**
```json
{ "anthropic": {
    "interactive": {"window_used_pct":40,"weekly_used_pct":30,"window_reset":"in 1h10m"},
    "agent_sdk_credit": {"remaining_pct":60,"refill":"in 12d"} } }
```

---

### TC-E2E-202: Codex/Gemini gauges appear when data exists (happy path)

**Description:** Additional provider pools render, labeled. (US-006 AC#2)

**Steps:**
1. Inject Codex usage; leave Gemini source absent.
2. Open the quota panel.

**Expected Results:**
- Codex gauge shown with its remaining.
- Gemini shows **"unknown / not tracked"** (not implied 100% free). (AC edge case #2)

---

### TC-E2E-203: Inferred values show confidence, not false precision (happy path)

**Description:** Interactive remaining (window math, inferred) is labeled estimated. (US-006 AC#3)

**Steps:**
1. Inject an interactive window value flagged as inferred.
2. Open the quota panel.

**Expected Results:**
- The interactive gauge is marked "estimated"/shows a confidence cue; the Agent SDK credit gauge (if from a precise source) is not falsely down-rated.

---

### TC-E2E-204: Exhausted pool is unmistakable (error path)

**Description:** A hard-stopped Agent SDK pool and a locked-out interactive window are clearly shown. (US-006 edge case #1)

**Steps:**
1. Inject Agent SDK credit = 0 (hard-stop) and interactive window = locked out.

**Expected Results:**
- Both gauges show exhausted + their reset/refill time.
- The display makes the asymmetry obvious (Agent SDK hard-stops with no fallback; interactive resets on the window).

## Cleanup

- Reset injected quota stubs.
