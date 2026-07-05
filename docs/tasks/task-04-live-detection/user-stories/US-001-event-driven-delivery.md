# US-001: Event-driven, size-independent board delivery

**Priority:** Must Have
**Status:** Ready
**Persona:** Operator (runs parallel agent sessions, watches the mission-control board)
**Estimated Complexity:** M

## User Story

As an **operator running several agent sessions at once**,
I want **the board to reflect a session's state change within a fraction of a second, without re-scanning the whole event history**,
So that **the board is a trustworthy real-time view and stays fast as events accumulate**.

## Acceptance Criteria

1. **Given** a session whose agent emits a lifecycle hook
   **When** that hook is appended to the event log
   **Then** ingest fires on the append via an FS-watch — not on the up-to-3s `Timer` — so the card updates sub-250ms typical. *Proven by asserting the watch fired (deterministic), not by wall-clock latency (anti-flake).*

2. **Given** a large existing event log
   **When** a new event arrives
   **Then** only the **newly appended bytes** are read. *This already holds — `HookEventTail.poll()` seeks to a persisted offset; the AC is a regression guard against reverting to a whole-file `Data(contentsOf:)` read.*

3. **Given** the event log grows past a size threshold
   **When** rotation triggers
   **Then** older events move to a rotated file, the live log stays bounded, and current session state is preserved across the rotation.

## Edge Cases

1. **Log truncated/rotated mid-read**
   - Trigger: file replaced or shrunk while tailing.
   - Expected: byte-offset resets to a safe point; no crash, no skipped current-state.

2. **Event burst**
   - Trigger: many hooks land within one coalesce window.
   - Expected: coalesced into one board update, still ≤250ms, no dropped final state.

3. **Cold start on a pre-existing large log**
   - Trigger: app launches with an already-big `events.jsonl`.
   - Expected: fast startup; reconstructs current state without reading every historical line each tick.

## Technical Notes

Demote the 3s `Timer` (`SessionsFeed.swift:73`) to a backstop and add a `DispatchSource` FS-watch as the primary trigger (DD-002). The incremental read (`HookEventTail.poll()`) and `occurred_at` (`SignalEvent.timestamp`) **already exist**. New work: FS-watch, inode-keyed rotation reset, and producer-side rotation/bounding in `.claude/scripts/ghostling-forward.sh`. Global `seq` is **not** emitted (the stateless forwarder can't produce a monotonic global counter — ordering uses `timestamp`).

## Dependencies

- **Requires:** none (foundational).
- **Enables:** US-002 (timestamped events make the reconciler's newest-wins join correct).

## Questions

- [x] Socket push vs `DispatchSource` file-watch — resolved in DD-002 (file-watch).

## Related

- Task: `../task-description.md` (Success Criteria 1, 2)
