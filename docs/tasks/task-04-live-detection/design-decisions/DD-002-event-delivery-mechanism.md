# DD-002: Event delivery — file-watch the append-only sink, not a socket

**Status:** Accepted
**Date:** 2026-07-01
**Deciders:** Operator (delegated), Claude

## Context

US-001 needs board updates ≤250ms after a hook fires. Today `SessionsFeed.swift:73`
polls on a 3s `Timer`, which floors latency at up to 3s. The tail read is
*already incremental* (`HookEventTail.poll()` seeks to a saved offset — no
whole-file re-read), but it is **not rotation-safe** (`resolveStart` only resets
the offset when `saved > fileSize`) and the log is **unbounded**. So the work is
event-driven delivery + rotation-safety, not fixing a whole-file read.

cmux solves this with an `events.jsonl` bus **plus** a Unix-domain socket
(`~/.cmuxterm/cmux.sock`) that pushes events. But cmux needs that socket for a
distinct reason: **cross-process** delivery to its CLI/second process attaching
to a running app. We are a **single process** — the app is the only reader of
its own append-only sink.

### Constraints

- Watcher-not-spawner: whatever we do stays a *reader* of an append-only file; no spawning.
- Must survive log rotation (DD-003 / cmux keeps `events.jsonl.1`).
- No new IPC surface unless it buys something.

## Options Considered

### Option A: Shorter poll interval + incremental read
Drop the timer to ~250ms and read only bytes past the last offset.
**Pros:** trivial; one-line-ish change; no new mechanism.
**Cons:** still a busy-wait 4×/s when idle; latency floored at the interval; not truly event-driven.
**Effort:** Low.

### Option B: `DispatchSource` file-system-object watch + incremental read
Arm a kernel FS watch on `events.jsonl`; on `.write` read from the saved offset; on `.rename`/`.delete` re-arm to the new file. Keep a low-frequency (~2–3s) timer as a backstop.
**Pros:** genuinely event-driven (sub-100ms typical); idle-cheap; no socket lifecycle/perms/port; still just reads the append-only file (watcher-safe).
**Cons:** must handle re-arm on rotation; FS events can be missed on some network filesystems (backstop covers it).
**Effort:** Medium.

### Option C: Unix-domain socket pushed by the forwarder
`ghostling-forward.sh` writes the file *and* pushes to a localhost socket the app serves.
**Pros:** exactly cmux's design; ready if we ever add a CLI/second reader.
**Cons:** socket server lifecycle, cleanup of stale socket, perms — all to solve a **cross-process** problem we don't have; the forwarder script gets heavier.
**Effort:** High.

## Decision

**Chosen: Option B** — `DispatchSource` FS-object watch on `events.jsonl` +
incremental read from a saved byte offset, with a low-frequency timer backstop.

### Ground-truth correction (2026-07-01, post-review)

- The **incremental read already exists** — `HookEventTail.poll()` (`:33`) seeks
  to a persisted offset and reads only the appended tail. This DD's new work is
  the **FS-watch trigger** (to demote the 3s timer at `SessionsFeed.swift:73` to
  a backstop) + **producer-side rotation/bounding**, not the offset read.
- **`occurred_at` already exists** as `SignalEvent.timestamp` (`SignalEvent.swift:37`,
  parsed by `SignalTimestamp.parse`). No new field.
- **Global monotonic `seq` is dropped**: the forwarder
  (`.claude/scripts/ghostling-forward.sh`) is a stateless per-hook appender
  invoked concurrently by many sessions; it can guarantee atomic-append line
  integrity but **not** a strictly-increasing global counter. Ordering relies on
  `timestamp` (+ per-poll arrival order), not `seq`.

### Key Factors

1. cmux's socket exists for **cross-process** delivery; single-process, a kernel file-watch gives the same latency with far less machinery.
2. Incremental read (offset, not whole-file) is the change that actually kills the size-dependent lag — independent of transport.
3. Backstop timer makes it robust to missed FS events and rotation without reintroducing busy-wait latency.

## Consequences

- **Positive:** ≤250ms with no new IPC surface; idle-cheap; preserves watcher posture.
- **Negative:** rotation/rename requires explicit re-arm of the watch (test it); offset bookkeeping to maintain.
- **Neutral:** if a CLI/second reader is ever needed, revisit toward Option C — the `seq`/`occurred_at`/rotation work done here transfers directly.

## Implementation Notes

- `HookEventTail`: hold **`(inode, offset)`**, not offset alone. Today
  `resolveStart` (`:50`) only resets to 0 when `saved > fileSize`; on rotation to
  a *fresh* file that has already grown past the old offset, `saved <= fileSize`
  and it silently skips the new file's head. Fix: reset the offset whenever the
  file's inode changes (`stat` the path / re-arm on `.rename`/`.delete`/`.revoke`).
- Backstop `Timer` at ~2–3s calls the same incremental read — cheap because it reads zero bytes when the offset is current.
- `ponytail:` file-watch over socket — add a socket only if a second process ever needs the stream.

## Related

- **Task:** `../task-description.md` (Success Criteria 1, 2)
- **Stories:** US-001 (primary); enables timeliness of US-002/US-005
- **Related Decisions:** DD-001 (reference cmux), DD-003 (rotation lives with the reconciler pipeline)
