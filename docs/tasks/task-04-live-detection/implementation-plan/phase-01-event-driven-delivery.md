# Phase 01: Event-driven delivery

**Status:** Complete (iteration 1)
**Estimated Effort:** M
**Dependencies:** none

## Objective

Kill the 3s poll and whole-file re-read so the board moves ≤250ms after a hook
fires, independent of `events.jsonl` size. Implements DD-002.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-001 | Must Have | M |

### Out of Scope (later phases)

- State correctness (US-002 → Phase 02)
- Resume / shell-integration (US-003/004 → Phase 03)

> **Ground-truth note (post-review):** the incremental offset read and
> `occurred_at` (`SignalEvent.timestamp`) **already exist**. Step 1 is now a
> *regression guard*, not new work. The new work is Step 2 (FS-watch) and Step 3
> (rotation-by-inode + producer bounding). Global `seq` is **dropped** (the
> stateless forwarder can't produce a monotonic global counter).

## Implementation Steps

### Step 1: Lock in the existing incremental read (regression guard)

**Description:** `HookEventTail.poll()` (`:33`) already seeks to a persisted
offset and reads only the appended tail (no whole-file read; `occurred_at`
already parsed). Add/keep a test that pins this so a future refactor can't
regress to a whole-file read.

**Files:**
- `app/Sources/GhostlingCore/HookEventTail.swift` — no behavior change; guard the existing seek→readToEnd path.

**Acceptance Criteria:**
- [x] A second read after one appended event returns only that event; offset advances by its byte length (read cost independent of file size).

**Tests:** TC-INT-001 (regression guard)

---

### Step 2: DispatchSource file-watch + backstop timer

**Description:** Arm a `DispatchSource.makeFileSystemObjectSource` on
`events.jsonl` (`.write .rename .delete`); on `.write` run the incremental read;
keep a low-frequency (~2–3s) `Timer` backstop calling the same read.

**Files:**
- `app/Sources/GhostlingApp/SessionsFeed.swift:73` — the `Timer.scheduledTimer` (3s) becomes the *backstop*; add the FS-object source as the primary trigger (`:52` is only the `interval` default).
- `app/Sources/GhostlingCore/HookEventTail.swift` — both triggers call the existing `poll()`.

**Technical Notes:**
- The FS source and the backstop must share the offset — `readNew()` is the only mutator; guard with the existing feed queue.

**Acceptance Criteria:**
- [x] Appending an event triggers a read within ≤250ms without the backstop firing.
- [x] Backstop still delivers if the FS event is missed.

**Tests:** TC-INT-002

---

### Step 3: Rotation-safe reader (by inode) + producer bounding

**Description:** Make the reader survive rotation by keying offset-reset on
**inode identity**, and have the producer rotate/bound the log.

**Files:**
- `app/Sources/GhostlingCore/HookEventTail.swift:50` — `resolveStart` currently resets only when `saved > fileSize`; on rotation to a fresh file already grown past the old offset it silently skips the head. Track `(inode, offset)` and reset when the inode changes.
- `.claude/scripts/ghostling-forward.sh` — rotate `events.jsonl → events.jsonl.1` past a size threshold so the log stays bounded (US-001 AC3). No `seq` stamping (unachievable globally); ordering uses the existing `timestamp`.

**Acceptance Criteria:**
- [x] Rotating mid-stream — including a new file already larger than the old offset — loses no event and produces no duplicate.
- [x] The event log stays bounded (producer rotates past the size threshold).

**Tests:** TC-UNIT-003 (reader inode-reset), TC-PROD-005 (producer rotation/bounding)

## Definition of Done

- [x] US-001 ACs bound to named green tests (TC-INT-001/002, TC-UNIT-003, TC-PROD-005).
- [x] `swift test` green; the existing incremental read is regression-guarded.
- [x] Watcher invariant intact — still only *reads* the append-only sink.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Missed FS events on network FS | Low | Med | backstop timer |
| Re-arm race on rotation | Med | Med | single `readNew()` mutator on the feed queue; TC-UNIT-003 |
| ≤250ms is timing-flaky in CI | Med | Low | assert "read fired on write" deterministically, not wall-clock latency |

## Related

- **Stories:** US-001
- **Decisions:** DD-002
- **Tests:** TC-INT-001, TC-INT-002, TC-UNIT-003, TC-PROD-005
