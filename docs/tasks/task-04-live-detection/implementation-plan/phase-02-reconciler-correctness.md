# Phase 02: Reconciler correctness

**Status:** Complete (iteration 2)
**Estimated Effort:** L
**Dependencies:** Phase 01 (rotation-safe, FS-driven delivery so the `timestamp`/`updatedAt` ordering is trustworthy; `occurred_at` already exists)

## Objective

Make card state trustworthy: recover dropped hooks, correlate the right session,
surface "needs you" as a first-class signal, and close deterministically.
Implements DD-003. Includes US-005 (a frozen board behind drill-in defeats
correct state).

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-002 | Must Have | L |
| US-005 | Should Have | S |

### Out of Scope (later phases)

- Resume / shell-integration (Phase 03)

## Implementation Steps

### Step 1: Wire the JSONLNormalizer recovery path

**Description:** When `HookNormalizer` yields no terminal transition (dropped
`Stop`), fall back to reconstructing it from the JSONL transcript tail.

**Files:**
- `app/Sources/GhostlingApp/SessionsFeed.swift:85` — call `JSONLNormalizer` as fallback (currently only `HookNormalizer` runs).
- `app/Sources/GhostlingCore/JSONLNormalizer.swift` — ensure it emits the missing `Stop`/exit from the transcript.

**Acceptance Criteria:**
- [x] With the `Stop` hook dropped, the card still leaves `running`.

**Tests:** TC-INT-010

---

### Step 2: Timestamp the per-dir join (plumb the existing `updatedAt`)

**Description:** Replace the timestamp-free `activityRank` join with newest-wins
using `HookSessionStore.Entry.updatedAt` — **the field already exists** (`:20`),
the fix is plumbing it through. `ppid` is **deferred** (DD-003 ground-truth
note): it has no producer and isn't needed for this AC.

**Files:**
- `app/Sources/GhostlingApp/BoardShell.swift:509` — `liveState(forDir:)` picks by `max(activityRank)` (timestamp-free); change to pick the entry with the newest `updatedAt`. This is exactly what that method's own `ponytail:` comment (`:506`) prescribes.
- `app/Sources/GhostlingCore/HookSessionStore.swift` — expose `updatedAt` on the entries surfaced to the board (already stored at `:148`).

**Technical Notes:**
- **Deferred `ppid`** (DD-003): if ever added, it's enrichment on top of the timestamp order, never the sole key — and observed (other-terminal) sessions won't carry it.

**Acceptance Criteria:**
- [x] Two sessions in the same dir: the newest-`updatedAt` state wins; a stale `blocked`/`waiting` from a prior run never out-ranks a fresh `running`.

**Tests:** TC-UNIT-012

---

### Step 3: Confirm the needs-attention signal fires from the real hook

**Description:** Attention is **already first-class** — `permissionRequest` maps
to `.waitingForInput` (`HookSessionStore.swift:159`), which is `needsAttention`
(`BoardCard.swift`). No new "`question` kind". The only gap is confirming the
real Claude Notification/permission hook actually normalizes to
`permissionRequest` (not `unknown`).

**Files:**
- `app/Sources/GhostlingCore/HookNormalizer.swift` — verify the Notification hook payload → `permissionRequest`; add the mapping if the real hook shape isn't covered.

**Acceptance Criteria:**
- [x] A real permission/notification hook event puts the card in needs-attention deterministically (via `permissionRequest → waitingForInput`).

**Tests:** TC-UNIT-013

---

### Step 4: Deterministic close; relax the 30s decay

**Description:** Close on explicit `sessionEnd`/exit; keep the stale-decay only
as a hard-kill backstop.

**Files:**
- `app/Sources/GhostlingCore/HookSessionStore.swift:54` — close on `sessionEnd`; decay becomes a long backstop, not the primary close.

**Acceptance Criteria:**
- [x] `sessionEnd` closes the card immediately (no 30s wait).
- [x] A hard-killed session (no `sessionEnd`) still eventually decays.

**Tests:** TC-UNIT-014

---

### Step 5: Keep the board live while drilled in (US-005)

**Description:** Remove the drill-in refresh suppression so state changes render
behind a focused terminal.

**Files:**
- `app/Sources/GhostlingApp/BoardShell.swift:497` — `applySessions` currently guards `if selection.focusedCardID == nil { refresh() }`; refresh on state change even when focused, without tearing down the focused terminal's superview.

**Acceptance Criteria:**
- [x] `applySessions` re-renders while `focusedCardID != nil`; no flicker of the focused terminal.

**Tests:** TC-INT-015

## Definition of Done

- [x] US-002 + US-005 ACs bound to named green tests (TC-INT-010/015, TC-UNIT-012/013/014).
- [x] `swift test` green; no card sticks in `running` after a dropped hook.
- [x] Attention count correct even while drilled in.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| JSONL fallback double-emits a Stop | Med | Med | dedupe by `sessionID`+timestamp against the hook path; TC-INT-010 |
| Removing drill-in freeze regresses render | Low | Med | TC-INT-015 + existing render tests |
| Real Notification hook doesn't map to `permissionRequest` | Med | Med | TC-UNIT-013 against the real payload shape |

## Related

- **Stories:** US-002, US-005
- **Decisions:** DD-003, DD-002 (timestamp ordering)
- **Tests:** TC-INT-010, TC-INT-015, TC-UNIT-012, TC-UNIT-013, TC-UNIT-014
