# Code Changes

Interface definitions for TASK-10a.

## Contents

| Name | Type | Status |
|------|------|--------|
| [Remote Hook Event Channel](remote-hook-event-channel.md) | Event (JSONL over ssh `tail -F`) | Draft |
| [RemoteTmuxCommand + PoolFirewall](remote-tmux-command.md) | Internal (module boundary) | Draft |
| [RemoteSpecSnapshot](remote-spec-snapshot.md) | Internal (on-disk format) | Draft |
| [Remote Host State + Card Surface](remote-host-state.md) | Internal (types + UI surface) | Draft |

## A note on shape

There are **no HTTP endpoints here, and that is the point.** This is a native Swift app
whose entire remote story is `ssh` + `tail` + `tmux`. Task-03's DD-002 established an
observe-only sink — no server, no port, no reply, no listener — and this task preserves
it structurally: the only `NWListener` in the app remains
`GhostlingCore/StaticFileServer.swift:14` (the LikeC4 pane). "No new listener" is asserted
as a **contract**, not checked by inspection.

So the contracts below are **module boundaries and wire-shaped line formats**. Where a
REST contract would specify auth and rate limits, these specify the ssh identity the
operator already has and the transport's replay/dedup behaviour.

## API Map

### Wire formats (remote → laptop)
- [remote-hook-event-channel.md](remote-hook-event-channel.md) — the two JSONL line kinds,
  their dedup keys, and the ingestion contract that stamps `ghostling_host`

### Constructors (laptop → remote)
- [remote-tmux-command.md](remote-tmux-command.md) — the only place an ssh argv is
  produced, and the firewall beneath it

### Persistence
- [remote-spec-snapshot.md](remote-spec-snapshot.md) — `PaneSnapshot.remote`; persists the
  spec, never the argv

### Types + surface
- [remote-host-state.md](remote-host-state.md) — `CardState.unreachable`,
  `RemoteHookInstallState`, the host chip, host-qualified recents

## What these contracts settled

Three open questions were answered by **reading source rather than assuming**, which is the
habit this task keeps having to re-learn — the last time it assumed a field existed (a
hostname), it did not. This round it assumed two more: that `iteration` identified a diff,
and that the forwarder had a version. Neither survived contact with the file.

1. **Task OQ2 / US-008's dedup key.** The forwarder is stateless for **state hooks**
   (the forwarder's header comment in `HookInstaller.swift` says so explicitly: no `seq`, no `occurred_at`) but
   **not** for **turn diffs**, which carry a per-session `iteration` counter persisted at
   `$state_dir/iteration` (the forwarder's `UserPromptSubmit` branch). So the key differs by line kind:
   `(host, sha256(raw line))` for state hooks, and
   `(host, session_id, iteration, sha256(diff_base64))` for diffs.
   Two traps, both found by reading the forwarder rather than trusting the field names:
   - Keying state hooks on the *normalized* `SignalEvent` looks equivalent and is wrong —
     `SignalTimestamp.parse` falls back to **arrival** time when `timestamp` is absent
     (`SignalEvent.swift:79`), so one replayed line normalizes to a different value on
     every reconnect. Hash the raw bytes, before normalization.
   - `iteration` is **not** a unique diff identity, though its name suggests one. It
     increments only on `UserPromptSubmit`; `turn_diff` emits on `Stop` and
     merely *reads* it, and `$state_dir/checkpoint` is never cleared. Two `Stop`s
     in one turn ⇒ two different diffs, one `iteration`. Hence the `sha256` tiebreak.

2. **US-005's `staleVersion` comparand.** It had none: `grep -c version HookInstaller.swift`
   = **0**, so an AC that said "the probe found an older forwarder" could not be made true
   by anything on disk. Chosen: `sha256` of the remote forwarder's bytes vs our embedded
   `forwarderScript`, both hashed on the laptop (no remote hash tool ⇒ no GNU/BSD split).
   A version marker line was rejected because it can be forgotten, and a forgotten bump
   reports `installed` while running different code.
3. **US-005 AC-4 / US-004's unnamed surface.** Named: a host chip on `SessionCard`, built
   on the same layer-backed render path as `repoChip()`. Proposed here, flagged for
   confirmation at `/saha:plan` — an interaction AC that doesn't name its surface cannot
   be turned into a test spec.

One premise was **corrected, then corrected again** — worth recording, because the second
correction is the instructive one. US-008 AC-1 read "no duplicate state events," but
re-ingesting an identical state event is largely idempotent already: `HookSessionStore.write`
records a transition only on real change (`HookSessionStore.swift:167-172`). The actual harm
from `-n 200`'s replay is a **stale line moving a card backwards**.

The example first chosen for that — a stale `UserPromptSubmit` re-opening a `done` session
— is **false**. `classify` returns `prior` for `.userInput` unless prior is
`.waitingForInput`/`.idle`, and `done` is deliberately sticky (`BoardCard.swift:28-33`). A
test from it cannot go red, so the AC would have shipped green and unproven. The real hole
is narrower and worse: `waitingForInput.detectorFallback` is `nil`, so a replayed
`SessionStart`/`PostToolUse` resolves `settled(.waitingForInput, .running)` → `.running` —
**a stale line silently extinguishes the attention signal**, the one thing the product
exists to raise. The reframing was right; the example was decoration until it was checked.

## A note on line citations

These contracts cite line numbers heavily, against a working tree where **10 of the 14
cited files are uncommitted**. `BoardShell.swift`'s `boundCardID` predicate moved four
times during planning — `1471 → 1482 → 1485 → 1528` — and the last hop happened *within*
the `/saha:contracts` session itself, invalidating a citation the same session had just
re-derived by grep. A number that decays faster than the document quoting it is not a
citation; it is a fact with a short fuse.

`BoardShell` was treated as the exception, on the premise that "the other files are
committed, so their numbers are safe." **That premise was false**, and this paragraph
asserted it while `HookInstaller.swift` sat uncommitted at +196 lines — every citation to
it off by ~28. The reviewer blessed those numbers twice; being checked twice by a reader
who trusts the same false premise is not verification. Decay is the general case here, not
a `BoardShell` quirk.

So the two files under active edit are **cited by construct, never by number**:
- `BoardShell.swift` — by symbol: `applySessions`, `promptRemoteTmux`, `chooseFolder`,
  `recentProjectDirs`/`rememberProjectDir`, `liveState(forDir:id:joinByDir:in:)`.
- `HookInstaller.swift` — by the shell construct inside `forwarderScript`: the
  `UserPromptSubmit` branch, the `Stop` branch, the `turn_diff` printf, the raw-append,
  the rotation block, the `plutil` gate.

Grep for the construct. Where line numbers survive (`RemoteTmuxCommand.swift`,
`PoolFirewall.swift`, `DiffModel.swift`, `StaticFileServer.swift` — the committed four,
plus the remaining `M` files re-derived at the close of `/saha:contracts`), treat the
**quoted code** as the identity and the number as a hint: if the code is not on the line,
the file moved, not the contract.

**Scope of that sweep: these four contracts, US-001/003/004, and DD-002/003/004.** It does
**not** cover `research/*.md` or `task-description.md`, which are dated snapshots of what
was true when they were written and are left alone deliberately. This paragraph earned its
own correction: it first claimed a blanket sweep, and the reviewer found five decayed
BoardShell numbers in the DDs it linked to — a claim of thoroughness is itself a citation,
and decays the same way.

## Related

- **Stories:** [US-001..009](../user-stories/README.md)
- **Decisions:** [DD-001..004](../design-decisions/README.md)
