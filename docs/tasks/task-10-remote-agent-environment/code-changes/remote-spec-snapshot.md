# Code Change: RemoteSpecSnapshot (persistence)

**Type:** Internal interface (on-disk format — `GhostlingCore`)
**Consumers:** `SessionRegistry` (write on persist, read on restore) — `GhostlingCore`;
`BoardSeed` — **`GhostlingApp/`**, not Core, despite the type above living in Core
**Status:** Draft

## Overview

A remote card must survive quit/reopen and reconnect to the tmux session still running on
its host. This contract defines what goes on disk — and, more importantly, what
**cannot**.

## The invariant this format carries

`SessionSnapshot.swift:6-9` states the watcher guarantee lives "in the shape of what we
persist, not just the restore code."

An earlier draft proposed persisting `commandOverride: [String]?` and re-running it. That
reads as a small additive change and is **a reversal**: a persisted
`["ssh","host","tmux new-session -A -s x 'claude -p …'"]` restores clean through every
gate, because at restore time there is no human and no constructor — just a string being
executed.

**Persist the constructor's input (the spec), not its output (the argv).** Same power;
the format has no field a command can go in. This is the task's reusable lesson:
*widening a shape that holds a guarantee silently relocates that guarantee into code, and
nothing warns you.*

> **Not a ban on `commandOverride` itself.** `BoardSeed.remoteTmux` already passes
> `commandOverride: argv` (`BoardSeed.swift:119`), and that is **fine and stays** — the
> name collides with the rejected draft, so read the scope carefully. In the seed, the
> argv was produced by `RemoteTmuxCommand.argv(for:)` moments earlier, in-process, from a
> validated spec, and is handed straight to a spawn. It is a **live value in memory**, not
> a **persisted** one. What this contract forbids is putting an argv **on disk**, where it
> outlives its constructor and comes back as an unvalidated string with no human present.
> Same bytes; the guarantee is about where they are allowed to rest.

## Data Model

### `PaneSnapshot.remote: RemoteSpecSnapshot?` (new optional field)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `host` | String | Yes | Revalidated on decode through the destination grammar. |
| `user` | String? | No | |
| `sessionName` | String | Yes | |
| `port` | Int? | No | |
| `identityFile` | String? | No | **See open question.** |
| `remoteDir` | String? | No | |

`nil` ⇒ a local pane. Codable, no custom coding keys.

**No field holds a command.** Assert this structurally — the test should fail if a
`String`/`[String]` field capable of naming an executable is ever added.

### Restore

```
PaneSnapshot.remote → RemoteTmuxSpec → RemoteTmuxCommand.argv(for:) → PoolFirewall.classify → spawn
```

The **same constructor** the create path uses. A hand-edited snapshot can at worst name an
odd host or session — it cannot smuggle `claude -p`, **but only because
[remote-tmux-command.md](remote-tmux-command.md) constrains the constructor's inputs.**
The format alone does not carry the guarantee. This is why US-001 ships first.

This is the sharpest of the three ssh call sites: it runs **at launch, from data on disk,
with no human present.**

## Versioning

**No `PaneSnapshot` version bump.**

A version mismatch is **ignored, not migrated** — `SessionRegistry.decodeUsable`
(`SessionRegistry.swift:172-176`) returns `nil` when
`snapshot.version != SessionSnapshot.currentVersion`. So a bump is not a migration; it
**discards every user's panes**. (`SessionSnapshot.swift:11-13` documents this intent but
is only a doc comment plus a constant — the behaviour is in `SessionRegistry`, and that
is where the test must target.)

Optional fields decode `nil` on old snapshots — the `claudeSessionID` precedent. An old
snapshot must still restore.

## Errors

| Case | Behavior |
|------|----------|
| `remote` absent (old snapshot) | Decodes `nil` → local pane. Unchanged behaviour. |
| `host` fails the destination grammar | Pane is **dropped**, not restored as local. Falling back to a local shell is bug 2. |
| Host unreachable at restore | Card restores as a remote card in `unreachable` (see [remote-host-state.md](remote-host-state.md)). **Never** a local shell. |
| Remote tmux session died while closed | `-A` creates a fresh session at the same name. Acceptable, but must not look like the old work survived. |

## The bug this fixes (proven red first)

`BoardSeed.swift:117` sets `projectDir: spec.target`, so the card persists
`cwd = "roman@host"`. `SessionRegistry.swift:275-277` does
`directoryExists(cwd) ? cwd : homeDirectory`, the check fails, and `reopenShell`
(`:251-253`) launches a **local** `$SHELL` in `$HOME` — still titled `roman@host · agent`.
It looks restored. It is a local shell.

## Deferred, and not at a discount

The full `SessionLocation` enum is **out**. Its real value was never elegance — it is that
`resolveCwd`'s local-path assumption would become a **compile error** instead of a silent
`$HOME` fallback, which is exactly how bug 2 shipped. This task adds new call sites
written against `projectDir: String` plus the nil convention, so promoting the enum later
is **more** expensive, not less. Tests were chosen over types deliberately, and the debt
is recorded here rather than in a changelog.

## Open Questions

- [ ] `identityFile` is reachable only through this snapshot today (`parse()` never sets
      it). Should the snapshot decode it at all, or is dropping it the safer default?
      Dropping it removes a field whose only safety is emission order.

## Related

- **Stories:** US-006 (owns), US-001 (prerequisite), US-004
- **Decisions:** DD-003 (owns), DD-004 (prerequisite)
