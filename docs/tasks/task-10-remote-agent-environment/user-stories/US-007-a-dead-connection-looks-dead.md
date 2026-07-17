# US-007: A Dead Connection Looks Dead

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator (the developer running agents on the board)
**Estimated Complexity:** M

## User Story

As an **operator**,
I want to **the board to tell me when it has lost contact with a host**,
So that **I am never shown a card that looks alive when nothing is actually being watched — a stale card is worse than no card, because I act on it**.

## Acceptance Criteria

- [ ] **AC-1:** When the per-host ssh transport process exits, affected cards read `unreachable` within **X = 5s** (one board poll cycle *of detection*; on this path there is no keepalive delay at all).
- [ ] **AC-2:** When the connection silently partitions, ssh keepalives (`ServerAliveInterval=15` × `ServerAliveCountMax=3`, ~45s worst case) trigger the same transition. Detection latency and `X` are distinct quantities and are asserted separately.
- [ ] **AC-3:** **The negative assertion, which is the load-bearing half:** a card whose host is unreachable **must not** read `running` or `waiting`. It reads a distinct `unreachable`. Assert the negative — not merely that some flag flipped.
- [ ] **AC-4:** `unreachable` is visible on the card, distinguishable from `done` and from "not observed."

## Edge Cases

1. **A healthy agent thinks for two minutes**
   - Trigger: a long turn with no hook output.
   - Expected behavior: the card stays `running`. This is why **`N` (a line-silence threshold) is retired, not assigned**: line silence is the wrong signal *in kind*, and no `N` is both fast enough to be useful and safe enough to never mislabel a working agent. Keepalives measure the **transport**, which is what this story is actually about.

2. **The connection recovers**
   - Trigger: Tailscale comes back.
   - Expected behavior: the relay reconnects and the card leaves `unreachable` — without duplicating the events it already saw (US-008).

3. **The host is up but the tmux session is gone**
   - Trigger: someone killed it.
   - Expected behavior: not `unreachable` — the transport is fine. A different state, or the card's existing terminal-exit handling.

## Technical Notes

This story is the direct application of the project's honest-degradation rule (`UsageEndpointReader.swift:12-14`, never fabricate a value): the failure being prevented is a **counterfeit** liveness reading, not a missing one.

AC-3 is written as a negative deliberately. A positive-only test ("the unreachable flag is true") passes while the card still renders `running` next to it.

## Dependencies

- **Requires:** US-003 (there is no transport to lose until the relay exists).
- **Enables:** US-006 edge case 2 (restore while a host is down must land in this state, not in a local shell).

## Execution History

| Iteration | Phase | Result | Notes |
|-----------|-------|--------|-------|
| - | - | - | Not yet executed |

## Questions

- [ ] Does the relay retry automatically and forever, or back off and surface a "reconnect" affordance? Forever-retry against a laptop that roams between networks is the common case; a silent retry loop that never succeeds is indistinguishable from a broken app.

## Related

- Task: [task-description.md](../task-description.md) — success criterion 6
- Design Decision: [DD-001](../design-decisions/DD-001-remote-hook-telemetry-transport.md) (sets the trigger and retires `N`)
