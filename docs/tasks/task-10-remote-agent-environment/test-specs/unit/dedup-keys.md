# Unit Test Spec: Dedup Keys

**File:** the ingestion step (new), between the relay's stdout and `HookNormalizer`
**Related:** US-008, [code-changes/remote-hook-event-channel.md](../../code-changes/remote-hook-event-channel.md)
**Priority:** High
**Status:** Draft
**Suite:** `app/Tests/GhostlingCoreTests/RemoteDedupTests.swift` (new)

## Overview

Two line kinds share one file and **do not have the same identity fields**. Getting either
key wrong fails silently — a duplicate diff, or a lost line. Unit-level because the keys
are pure functions of bytes; the behaviour they protect is asserted at E2E
(TC-E2E-006) and integration (TC-INT-005).

## Test Cases

### TC-UNIT-008: State hooks key on raw line bytes (US-008 AC-3)

**Input:** the same raw line, ingested twice.
**Expected:** key `(ghostling_host, sha256(rawLine))` is equal both times.

**Notes — the trap, which looks equivalent and is wrong:** keying on the **normalized**
`SignalEvent` fails silently. `SignalTimestamp.parse` falls back to **arrival** time when
`timestamp` is absent (its final `return arrival`), so one byte-identical line replayed on
reconnect normalizes to a different `Date` and a non-equal `SignalEvent`.

**Dedup must happen on the raw bytes, before normalization.** The line already carries the
`ghostling_card_id` splice at hash time, which is stable per card, so hashing the whole
line is safe.

Same reasoning rules out a **byte cursor**, which AC-3 names: a cursor cannot satisfy
content-based dedup across a rotation.

---

### TC-UNIT-009: Turn diffs key on four parts (US-008 AC-2)

**Input:** two `turn_diff` lines, same `session_id` and `iteration`, **different diffs**.
**Expected:** both admitted. Key: `(ghostling_host, session_id, iteration, sha256(diff_base64))`.

**Notes — `iteration` is not a unique diff identity, though its name says otherwise.**
Read the forwarder's two branches:
- `iteration` increments **only** on `UserPromptSubmit` (its branch).
- `turn_diff` emits on **`Stop`**, which **reads** the counter without incrementing.
- The `Stop` branch clears `$diff_path` but **never clears `$state_dir/checkpoint`**, so it
  stays armed.

So two `Stop`s without an intervening `UserPromptSubmit` emit **two different diffs under
one `iteration`**. Keyed on the triple alone, the second is silently eaten. **The `sha256`
tiebreak is load-bearing, not defensive** — this case is why.

---

### TC-UNIT-010: The diff key ignores `timestamp` and `cwd_base64`

**Input:** the same diff content, two different `timestamp` values.
**Expected:** deduped — one entry.

**Notes — why not just `sha256(raw line)`, as for state hooks?** Because the raw bytes
include `timestamp` (`date +%s`), so two `Stop`s emitting the same diff in different
seconds hash differently and **both are admitted**. The composite key deliberately ignores
`timestamp`/`cwd_base64` and keys on **content identity**.

The asymmetry is principled: **state hooks can afford raw bytes because their duplicates
fold idempotently into state; diffs accumulate into a list, so theirs must be
recognised.** (`HookSessionStore.write` compares against `currentState` and appends a
transition only `if changed`.)

---

### TC-UNIT-011: `turn_diff.session_id` is sanitized; state hooks' is raw

**Input:** a `session_id` containing characters outside `[:alnum:]_.-`.
**Expected:** the diff line's `session_id` is the **sanitized** form (`$safe_session` =
`session_id | tr -cd '[:alnum:]_.-'`); the state hook's is Claude's **raw** value.

**Notes:** any join across the two kinds **crosses a sanitization boundary**. Join on the
sanitized form, or not at all. This test exists so a future join is written knowing that.

## Parameterized Cases

| Scenario | Key differs? | Admitted? |
|---|---|---|
| identical state line replayed | no | no — deduped |
| same line, different host | yes | yes |
| same diff, different `timestamp` | no | no — deduped |
| different diff, same `iteration` | yes | **yes — the case that ships broken** |
| state line, `timestamp` absent, replayed | no (raw bytes equal) | no — deduped |

## Mocks Required

**None.**
