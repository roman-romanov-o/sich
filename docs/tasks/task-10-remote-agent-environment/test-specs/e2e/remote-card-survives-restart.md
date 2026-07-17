# E2E Test Spec: A Remote Card Survives Restart

**Related Stories:** US-006
**Priority:** Critical
**Status:** Draft
**Suite:** `app/Tests/GhostlingAppTests/RemoteRestoreE2ETests.swift` (new)

## Overview

Quit with a remote card running; relaunch; the card reconnects to its remote tmux session
and its telemetry rebinds. Same substitution as
[remote-session-lands-on-its-card.md](remote-session-lands-on-its-card.md): real
persistence, real decode, real argv rebuild, real firewall — a substitute child at the
ssh seam.

## Preconditions

- A `PaneSnapshot` store in a temp dir.
- A remote card whose spec is `RemoteTmuxSpec(user: "roman", host: "boxA", sessionName:
  "task-10", remoteDir: "/home/roman/proj")`.

## Test Cases

### TC-E2E-007: The restored card is remote, not a local shell (US-006 AC-1)

**Written red first, and the red is specific.** Today the remote seed in `BoardSeed` passes
`projectDir: spec.target`, so the card persists `cwd = "roman@boxA"`. `SessionRegistry`'s
`resolveCwd` falls back to the home directory when `directoryExists` fails; `roman@boxA` is
not a directory, so `reopenShell` launches a **local `$SHELL` in `$HOME`** — still titled
`roman@boxA · agent`.

That title is why this ships silently: the card looks right and is a local shell. The test
must assert the **argv**, not the title.

**Steps:** persist the card; discard in-memory state; restore from disk.

**Expected Results:**
- The restored pane's argv is an **ssh** argv targeting `roman@boxA`, not
  `/bin/sh -c $SHELL`.
- Assert against the argv. A title assertion passes today and proves nothing.

---

### TC-E2E-008: The snapshot persists the spec, not the argv (US-006 AC-2)

**Description:** The reusable invariant of this task — **persist the constructor's input
(spec), not its output (argv)**. An argv is a *result* that already passed the firewall;
storing it moves the guarantee out of the shape and into restore code, where the next
reader cannot see it. A spec on disk must be re-run through `argv(for:)` and re-checked.

**Expected Results:**
- The on-disk JSON contains `user`/`host`/`sessionName`/`remoteDir` and **no `argv` key,
  no ssh flags, no `-t`, no `tmux` string**. Assert on the decoded JSON keys — "a struct
  is not a constraint; its constructor is," so assert the persisted shape field by field
  rather than inferring from the type name.

---

### TC-E2E-009: No `PaneSnapshot` version bump (US-006 AC-3)

**Description:** `SessionRegistry.decodeUsable` drops the whole store on a version
mismatch — a bump is **not a migration, it is data loss**: every existing local card
vanishes on the upgrade that adds remote support.

**Expected Results:**
- `remote` decodes as an **optional additive field**; the version constant is unchanged.
- **A v1 snapshot written before this feature still decodes**, with `remote == nil` and
  the card intact. This is the assertion that makes the AC real.

---

### TC-E2E-010: The restored card rebinds telemetry (US-006 AC-4)

**Steps:** after restore, append a hook line carrying the original `GHOSTLING_CARD_ID`.

**Expected Results:** the restored card moves. Restoring the terminal without the relay
would reproduce today's bug in a new place — a working terminal above a card that never
moves.

---

### TC-E2E-011: The rebuilt argv passes `PoolFirewall` (US-006 AC-5)

**Description:** The sharpest of the three ssh call sites: it runs **at launch, from data
on disk, with no human present**.

**Expected Results:**
- A persisted spec with `host: "-oProxyCommand=sh -c 'claude -p x'"` is **refused at
  restore** and does not spawn.
- Assert it routes through the existing `PoolFirewall.classify` chokepoint in
  `SessionRegistry`'s spawn path rather than composing an argv beside it. The chokepoint
  exists but has never been handed an ssh argv — `reopenShell` always built a local
  `/bin/sh -c …`. This is a tightening of an existing gate, not a new one.

## Cleanup

Remove the temp snapshot store.
