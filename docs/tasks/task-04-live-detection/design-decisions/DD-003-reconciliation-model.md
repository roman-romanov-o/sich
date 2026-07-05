# DD-003: Reconciliation model — ppid lineage + workspace index + wired JSONL fallback

**Status:** Accepted
**Date:** 2026-07-01
**Deciders:** Operator (delegated), Claude

## Context

The card-state weaknesses that make the board untrustworthy (US-002):

- **Dropped `Stop` hook is unrecoverable** — `JSONLNormalizer` exists but is
  never wired (`SessionsFeed.swift:85` only calls `HookNormalizer`); a card
  sticks in `running`.
- **Wrong multi-session state** — the join is timestamp-free projectDir
  (`BoardShell.swift:509`); stale state can out-rank fresh even though the store
  already carries `updatedAt`, and two sessions in one dir collide.
- **30s stale-decay guess** (`HookSessionStore.swift:54`) instead of a
  deterministic close.

*(Attention is **not** a gap — `permissionRequest → waitingForInput → needsAttention`
is already wired at `HookSessionStore.swift:159`; see Consequences.)*

cmux's correctness comes from: `ppid` process-lineage binding,
`activeSessionsByWorkspace` index, `occurred_at` timestamps, a first-class
`question` kind, and an explicit `sessionEnd`/exit — layered over a persisted,
workspace-indexed store. It also carries a heavier `workstream.jsonl` semantic
layer we don't need yet.

## Options Considered

### Option A: Keep the projectDir join, just add timestamps
**Pros:** smallest change.
**Cons:** doesn't fix dropped-hook recovery or two-sessions-one-dir; attention still inferred.
**Effort:** Low.

### Option B: ppid lineage + workspace index + occurred_at + wired JSONL fallback + deterministic close
Bind a hook event to its session by **process lineage** (`ppid`) where
available, keyed within an `activeSessionsByWorkspace` index; break ties by
`occurred_at`; **wire `JSONLNormalizer`** as the recovery path so a dropped
`Stop` is reconstructed from the transcript; make `question` a first-class
needs-attention state; close on explicit `sessionEnd`/exit, keep a *relaxed*
backstop decay only for hard-kill.
**Pros:** fixes all four weaknesses; mirrors cmux's proven correctness; deterministic → testable.
**Cons:** ppid isn't available for every session flavor (see subtlety); more state to persist.
**Effort:** Medium-High.

### Option C: Adopt cmux's full `workstream.jsonl` semantic layer
**Pros:** richest model; matches cmux 1:1.
**Cons:** more than US-002 needs; larger surface, slower to land.
**Effort:** High.

## Decision

**Chosen: Option B, timestamp-first.** Take cmux's correctness primitives
without its full semantic layer (C) — but **`occurred_at`/`updatedAt` ordering
is the primary correlation mechanism, and `ppid` is best-effort enrichment only,
deferred**.

### Ground-truth correction (2026-07-01, post-review)

Verified against the code, three of the four inputs already exist:

- **`updatedAt` already exists** on `HookSessionStore.Entry` (`HookSessionStore.swift:20`) — the fresh-vs-stale fix is *plumbing it into* `BoardShell.liveState` (`BoardShell.swift:509`), exactly what that method's own `ponytail:` comment prescribes. No `ppid` needed for the target AC (US-002 AC2).
- **Attention is already first-class**, not inferred: `permissionRequest` maps to `.waitingForInput` (`HookSessionStore.swift:159`), which is `needsAttention` (`BoardCard.swift`). So there is no new "`question` kind" to add — the work is only to confirm the real Notification hook produces `permissionRequest`.
- **`ppid` has no producer**: the forwarder (`.claude/scripts/ghostling-forward.sh`) stamps nothing and appears nowhere in the codebase. It is absent for observed sessions by design and not required by any AC. → **Deferred**; add only if a future need justifies emitting it.

So the real, confirmed weaknesses this DD fixes are: (a) the **unwired
`JSONLNormalizer`** fallback, (b) the **timestamp-free join** (fix by plumbing
`updatedAt`), and (c) the **30s decay** as primary close (fix with deterministic
`sessionEnd`).

### Key Factors

1. `updatedAt` timestamp ordering fixes fresh-vs-stale with a field that already exists — no new correlation key, no `ppid` producer.
2. Deterministic close + wired JSONL fallback replace two guesses (dropped-hook, 30s decay) with recoverable truth.
3. `ppid`/workspace-lineage stays available as a documented future enrichment, not scope now.

## Consequences

- **Positive:** correct state across dropped hooks and shared dirs, using a field (`updatedAt`) that already exists; closes are deterministic.
- **Negative:** JSONL fallback must dedupe against the hook path (by session + timestamp) to avoid a double transition.
- **Neutral:** backstop decay stays (relaxed) purely for hard-kill where no `sessionEnd` arrives; `ppid` enrichment deferred.

## Implementation Notes

### Correlation — timestamp-first
- Primary: plumb `HookSessionStore.Entry.updatedAt` (already present, `:20`) into `BoardShell.liveState` (`:509`) so the newest state wins the per-dir join instead of `activityRank` (which is timestamp-free and can let a stale `blocked` out-rank a fresh `running`).
- **Owned vs observed** (future `ppid`): owned sessions run in our PTY (child pid known); observed sessions may have no `ppid`. If `ppid` is ever added, it's an *enrichment* on top of the timestamp order — never the sole key.

### Recovery
Wire `JSONLNormalizer` at `SessionsFeed.swift:85` (currently only
`HookNormalizer.normalize` runs) as the fallback when the hook path is missing
the terminal transition — reconstruct `Stop`/exit from the JSONL transcript
tail, deduped by `sessionID` + timestamp against the hook path.

## Related

- **Task:** `../task-description.md` (Success Criteria 3, 4, 5)
- **Stories:** US-002 (primary); US-004 sharpens the cwd/workspace key
- **Related Decisions:** DD-002 (delivery), DD-001 (reference cmux)
