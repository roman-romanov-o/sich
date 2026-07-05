# US-002: Trustworthy card state (reconciler correctness)

**Priority:** Must Have
**Status:** Ready
**Persona:** Operator
**Estimated Complexity:** L

## User Story

As an **operator**,
I want **each card to always show its session's true current state — even when a hook is dropped or several sessions share a directory**,
So that **I never act on a stale or wrong column**.

## Acceptance Criteria

1. **Given** a session that finishes but whose `Stop` hook is dropped
   **When** the session's end is otherwise observable (lifecycle / JSONL fallback)
   **Then** the card leaves `running` and reaches done — the currently-dead `JSONLNormalizer` fallback is wired in (`SessionsFeed.swift:85`).

2. **Given** two sessions in the same project directory
   **When** one is freshly `running` and another holds a stale `blocked`/`waiting`
   **Then** the card shows the **freshest** session's state, ordered by `updatedAt` — not the stale one (fixes the timestamp-free `activityRank` join at `BoardShell.swift:509`). *`updatedAt` already exists on the store entry (`HookSessionStore.swift:20`); the fix is plumbing it into `liveState`.*

3. **Given** an agent requests permission (a Notification/permission hook)
   **When** that explicit event is received
   **Then** the card is in **needs-attention**. *Already wired — `permissionRequest` → `.waitingForInput` → `needsAttention` (`HookSessionStore.swift:159`); the AC guards that the real hook payload normalizes to `permissionRequest`, not that a new `question` kind is added.*

4. **Given** a session's owning process exits
   **When** the exit is detected
   **Then** the card transitions promptly (deterministic close), rather than waiting the fixed 30s stale-decay (`HookSessionStore.swift:54`).

## Edge Cases

1. **Out-of-order hooks**
   - Trigger: events arrive out of sequence.
   - Expected: `updatedAt`/`timestamp` ordering yields the latest true state, not the last-received.

2. **Two sessions, same dir, both running**
   - Trigger: overlapping sessions in one workspace.
   - Expected: both tracked via a workspace index; the card reflects the correct owned/active one.

3. **Process exits without a `sessionEnd`/`Stop`**
   - Trigger: hard kill.
   - Expected: a longer **backstop decay** still clears the card (don't remove the safety net entirely).

## Technical Notes

Two confirmed fixes: (a) **wire `JSONLNormalizer`** as the fallback at `SessionsFeed.swift:85` (only `HookNormalizer` runs today), deduped by `sessionID`+timestamp; (b) **plumb `updatedAt`** into `BoardShell.liveState` (`:509`) so newest-wins replaces the timestamp-free `activityRank`. Relax (not delete) the 30s decay (`HookSessionStore.swift:54`) once deterministic `sessionEnd` close exists. `ppid`/workspace-lineage is **deferred** (no producer; not needed for these ACs — see DD-003). Attention is already first-class via `permissionRequest`.

## Dependencies

- **Requires:** US-001 (timestamped events).
- **Enables:** trustworthy attention count (`Attention.swift`).

## Questions

- [ ] Backstop decay duration once `sessionEnd`/process-exit close exists.

## Related

- Task: `../task-description.md` (Success Criteria 3, 4, 5)
