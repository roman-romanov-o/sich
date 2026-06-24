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
- **Stub substitution at the integration boundary** — the test calls the handler
  directly (`panel.goBack()`, `shell.returnToBoard()`, an `@objc` action, a value
  type's method) instead of supplying the stimulus the *user* supplies. It proves
  the handler works; it says nothing about whether the user's action reaches it.
  This is what shipped a drill-in where `Esc` typed an escape symbol into the
  terminal three times, all green: every "Esc returns to board" test called
  `goBack()` directly, and none dispatched an actual key event past the terminal
  (the real first responder, which was eating `Esc`).

## Interaction-AC Binding Rule (checkable — do not waive)

**If an acceptance criterion names a physical input modality, its covering test
must reproduce that input as an event, not call the handler.**

Apply mechanically:

1. Does the AC text contain `press`, `Esc`/`key`/`keyboard`/`key equivalent`,
   `click`/`tap`, `type`, `drag`, or `gesture`? → it is an **interaction AC**.
2. For an interaction AC, at least one covering test must, in its body, construct
   or dispatch a real input event — look for `NSEvent`, `keyDown`, `sendEvent`,
   `performKeyEquivalent`, `performClick`, `cancelOperation`, `mouseDown`, or a
   declared event-layer seam (`onEscape`, a key router) that is itself driven by a
   constructed event in another test.
3. A test whose only stimulus for that AC is a direct call to the action method
   (`goBack`, `returnToBoard`, a `@objc` selector, a value-type mutator) does
   **not** cover it. Mark the AC **uncovered / interaction-path unverified** —
   never fold it into "pixel sign-off." Whether a key *returns* is machine-testable
   (event dispatch); only whether it *feels* instant is human-visual. Keep them
   separate.
4. The covering test must be a genuine red→green: it must fail against code where
   the wiring is absent. A test that passes no matter what (because it calls the
   handler) is not evidence.

Also verify the **harness is faithful**: if the real app wires callbacks
(`onClose`, `onSelect`) in one place (e.g. `wireInteractions`) and the test builder
skips it, every "click → …" test silently bypasses the real chain. The test setup
must wire what the app wires.

## What Good Looks Like

- Asserts observable behavior, not implementation details
- Uses minimal mocking (only external boundaries)
- Verifies edge cases and error handling
- **Interaction tests supply the user's stimulus** (a dispatched event), reach the
  handler through the real responder/callback chain, and fail when that chain is
  broken

## Output Contract

When requested, return a JSON block:

```json
{
  "critique_passed": true,
  "test_quality_score": "A-F",
  "fix_info": ""
}
```
