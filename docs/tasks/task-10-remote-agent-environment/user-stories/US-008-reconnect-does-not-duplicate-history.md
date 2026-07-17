# US-008: Reconnect Does Not Duplicate History

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator (the developer running agents on the board)
**Estimated Complexity:** M

## User Story

As an **operator**,
I want to **a reconnect after a dropped connection to pick up where it left off, not replay what I have already seen**,
So that **my card does not jump backwards through states it already passed, and drill-in does not show me the same diff twice**.

## Acceptance Criteria

- [ ] **AC-1:** A transport reconnect that re-sends already-seen lines **never moves the card backwards**. The card's state sequence is unchanged versus a connection that never dropped. The test is written from this replay: **a stale `SessionStart`/`PostToolUse` arriving against a `.waitingForInput` prior must not resolve to `.running`** — i.e. a replay must not extinguish the attention signal. Secondary: a stale `Stop` must not move `.running` → `.idle`.
  _(Sharpened twice at `/saha:contracts`. First: an earlier wording said "no duplicate state events," but re-ingesting an identical state event is largely idempotent already — `HookSessionStore.write` records a transition only on real change, `HookSessionStore.swift:167-172`. Second, and the reason the example above is oddly specific: the **obvious** example — a stale `UserPromptSubmit` re-opening a `done` session — is **false**, and a test from it cannot be made red. `classify` returns `prior` for `.userInput` unless prior is `.waitingForInput`/`.idle`, and `done` is deliberately sticky via `settled` → `prior.detectorFallback ?? next` (`BoardCard.swift:28-33`). The real hole is that `waitingForInput.detectorFallback` is `nil`, so `settled(.waitingForInput, .running)` = `.running`. Asserting the state sequence is strictly stronger than counting events — but only if the replay chosen can actually regress.)_
- [ ] **AC-2:** The same reconnect produces **no duplicate diffs** in drill-in. Key: `(host, session_id, iteration, sha256(diff_base64))`. The `sha256` tiebreak is **load-bearing, not defensive**: `iteration` increments only on `UserPromptSubmit` (the forwarder's `UserPromptSubmit` branch) while `turn_diff` emits on `Stop` reading it without incrementing, and `$state_dir/checkpoint` is never cleared — so two `Stop`s in one turn emit two different diffs under one `iteration`. Assert that case; keyed on the triple alone the second diff is silently eaten.
- [ ] **AC-3:** State-hook dedup is **content-based over the raw line bytes**, keyed `(host, sha256(line))`. Two implementations that look equivalent are wrong and must be excluded by test:
  - a **byte cursor** — `tail -n 200 -F` reopens with no memory of the previous connection's offset, and the remote file may have rotated between connections, so byte positions do not survive the event this AC is about. Assert against a replay starting at a different offset than the original read.
  - the **normalized `SignalEvent`** — `SignalTimestamp.parse` falls back to *arrival* time when `timestamp` is absent (`SignalEvent.swift:72-80`), so one byte-identical line replayed later normalizes to a different `Date` and a non-equal value. Hash **before** normalization. Assert with a timestamp-less line replayed at a later arrival.

## Edge Cases

1. **Two genuinely identical events**
   - Trigger: the same hook fires twice with an identical payload — e.g. two turns that changed nothing.
   - Expected behavior: arises for **both** kinds. For state hooks, `timestamp` is second-granularity, so two byte-identical `PostToolUse` lines within one second are genuinely possible; eating one is **harmless**, because the fold into state is idempotent (AC-1). For diffs it arises only when content *and* `iteration` match — an earlier draft claimed diffs were immune because "two diffs of one session always differ in `iteration`", which the forwarder disproves (AC-2). Contract, for both: **prefer eating a true duplicate over admitting a stale replay.** This is a deliberate asymmetry, not an oversight.

2. **The relay reconnects after a long outage**
   - Trigger: `-n 200` replays a window that the app partly saw and partly missed.
   - Expected behavior: the seen prefix is suppressed, the unseen suffix is ingested. Partial overlap is the normal case, not an edge one.

3. **The remote file rotated during the outage**
   - Trigger: `mv` + recreate.
   - Expected behavior: `tail -F` follows by name and handles it (research doc 02, risk 5). The dedup key must not assume file continuity.

## Technical Notes

This covers the failure that US-004 AC-3 does **not**: same-host **replay**, rather than cross-host conflation. They are different bugs with different fixes and both are live.

Bounding the dedup memory matters — an unbounded set of every line ever seen grows for the lifetime of the app. **Chosen at `/saha:contracts`:** 500 entries per host, FIFO. It only has to outlive one reconnect's `-n 200` replay, and it is per host so a chatty host cannot evict another's history and resurrect its replays. Full reasoning in [code-changes/remote-hook-event-channel.md](../code-changes/remote-hook-event-channel.md) § Dedup memory bound.

## Dependencies

- **Requires:** US-003 (the transport), US-007 (reconnect is what this story dedups against).
- **Enables:** nothing downstream; it is a correctness guard on the transport.

## Execution History

| Iteration | Phase | Result | Notes |
|-----------|-------|--------|-------|
| - | - | - | Not yet executed |

## Questions

- [x] ~~**What is the dedup key?** (Task OQ2)~~ **Resolved at `/saha:contracts` by reading the forwarder, not by assuming.** The answer differs by line kind, which the question did not anticipate. The forwarder is stateless for **state hooks** — it says so explicitly (the forwarder's header comment in `HookInstaller.swift`: no `seq`, no `occurred_at`, "a per-hook appender can't produce a global monotonic counter") — but **not** for **turn diffs**, which carry a per-session `iteration` counter persisted at `$state_dir/iteration` (the forwarder's `UserPromptSubmit` branch) and emitted at `:212-213`. So: `(host, session_id, iteration)` for diffs, `(host, sha256(raw line))` for state hooks. Full contract in [code-changes/remote-hook-event-channel.md](../code-changes/remote-hook-event-channel.md).
- [x] ~~Dedup memory bound is still unchosen.~~ **Resolved at `/saha:contracts`:** 500 entries per host, FIFO — see Technical Notes. AC-3's eviction assertion needs a stated bound, so this could not stay open.

## Related

- Task: [task-description.md](../task-description.md) — success criterion 7, OQ2
- Design Decision: [DD-001](../design-decisions/DD-001-remote-hook-telemetry-transport.md)
