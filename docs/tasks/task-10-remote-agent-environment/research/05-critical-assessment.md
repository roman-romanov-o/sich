# Research: Critical Assessment — Is TASK-10 Well-Scoped?

**Date:** 2026-07-16
**Status:** Complete

## Summary

**Proceed, but split it.** As stated ("run tasks in remote env + a remote file
picker") the task bundles two independent features with wildly different costs,
and the cheap-sounding one (the picker) is worth little until the expensive one
(telemetry transport) exists. Recommend **three sequential tasks**; only the first
is a coherent unit of work.

## The honest shape of the problem

The user's ask has a hidden dependency order:

```
"run tasks in a remote env"  ──depends on──▶  hook telemetry transport (doesn't exist)
                             ──depends on──▶  remote hook install (doesn't exist)
                             ──depends on──▶  portable forwarder (plutil = macOS-only)
"file picker in remote env"  ──depends on──▶  host-aware projectDir (wide refactor)
```

Today, ⌘⇧R already gives a working remote **terminal**. What it does not give is a
remote **card** — something the board can reason about. The gap between those two
is the whole task, and it is mostly invisible from the UI.

## What "done" would actually require (evidence in docs 01-04)

| # | Work | Cost | Needed for the user's ask? |
|---|---|---|---|
| 1 | Make the forwarder POSIX/portable (drop `plutil`) | S | **Yes** — hard blocker on Linux |
| 2 | `installRemote(host:)` — push forwarder + patch remote `~/.claude/settings.json` | M | **Yes** |
| 3 | `ssh tail -F` transport + per-host cursor + reconnect supervision | M | **Yes — the core** |
| 4 | Namespace observed sessions/diffs by host | S | **Yes** |
| 5 | Remote card identity binding (design decision) | M | **Yes** |
| 6 | Fix remote-card persistence/restore (persist spec, re-run ssh argv) | S-M | **Yes** — currently broken |
| 7 | Host-aware `projectDir` refactor | **L** | Only for #8 |
| 8 | Remote folder picker (ssh+ls, ControlPersist, async) | M | The user's 2nd ask |
| 9 | Remote quota | — | **No — cut** (account-level already; doc 04 §1) |
| 10 | Remote worktrees | — | **No — cut** (doc 04 §4) |

## Recommended split

**TASK-10a — Remote sessions reach the board** (items 1-6)
The real feature. A remote card moves through columns, shows attention, and shows
diffs, exactly like a local one. Ends with: open ⌘⇧R, run `claude` in the tmux,
watch the card go running → waiting → done on the laptop. That is a demoable,
independently valuable slice — and it is what "run tasks in remote env" means.

**TASK-10b — Remote folder picker** (items 7-8)
Only worth doing after 10a, because picking a remote folder for a card the board
can't observe just produces a prettier dead card. Contains the one **L** item
(host-aware `projectDir`), so it deserves its own budget.

**Cut entirely:** remote quota, remote worktrees.

## What I'd challenge in the task as framed

1. **"We should also have file picker there" is likely over-asked.**
   The user probably has 1-3 repos on that box. A **remote-recents list** (type the
   path once, it's remembered) is ~10% of a tree browser's cost and plausibly 90%
   of the value — and it sidesteps the ssh-latency UX problem entirely (doc 03,
   risk 2). **Ask before building a browser.** This is the clearest candidate for
   scope reduction in the whole task.

2. **The ⌘⇧R NSAlert may be the wrong foundation to build on.**
   Three raw text fields in an `NSAlert` (`BoardShell.swift:591-626`) is a
   power-user escape hatch, not a product surface. If remote is meant to be a
   first-class "where does this run?" choice, it belongs as a stage in
   `CreateCardPalette`, and the NSAlert should be retired — otherwise this project
   will maintain two divergent creation paths forever. That is a product decision
   the research can't make.

3. **Bootstrapping is the silent-failure risk, and this project has been bitten by
   exactly this before.**
   `board-status-bug-was-missing-global-hooks` was *literally* "cards never move
   because hooks weren't installed" — locally. Remote reintroduces it with a worse
   failure mode (the terminal works perfectly, so nothing looks wrong). **Any plan
   must include a visible per-host hook-install state.** Do not let this be
   inferred.

4. **Don't build a remote agent binary.** It will be proposed (doc 03, Option C).
   It solves listing + transport + quota "elegantly" and costs a cross-compiled
   distribution pipeline this project has no infrastructure for. `ssh` + `tail` +
   `ls` does the job with zero remote install and zero new trust surface. This is
   the premature-abstraction trap for this task.

## Anti-patterns to watch for in planning

- **Building the picker in `FolderPicker.swift`** — that file is dead
  (doc 03, finding 1). Would ship green-but-unreachable code, the exact trap in
  `saha-creation-had-no-ui-entry-point`.
- **A listener / HTTP wire for hooks** — reintroduces precisely what DD-002 deleted
  (`pyproject.toml:1-8`) and makes the hook block on network I/O, violating the
  forwarder's "never slow the watched session" contract (`HookInstaller.swift:116-117`).
- **Assuming the sidecar exists.** It doesn't. Two memory notes are stale on this.
- **Trusting `docs/tasks/task-05-turn-diffs/task-description.md:28`** ("remote
  sessions already reach the board over the tailscale channel"). This is false and
  has been sitting in the docs unchallenged.

## Assumptions I could NOT verify (must ask the user)

1. **Is the remote box Linux or macOS?** Decides urgency of the `plutil` fix
   (doc 02, risk 1). Not inferable from the repo.
2. **Same Anthropic account on both machines?** If yes, quota is a non-issue
   (doc 04 §1). If no, the gauge is silently wrong for remote cards.
3. **One remote host or several?** Multi-host makes per-host cursors/supervision
   real work; single-host makes the transport nearly trivial.
4. **Tree browser or remote-recents?** The biggest scope lever in the task.
5. **Keep or retire the ⌘⇧R NSAlert?**

## Verdict

**Proceed with TASK-10a. Defer 10b pending the answer to Q4. Cut quota and
worktrees.** The architecture is more remote-ready than expected in the two places
that would have been expensive to fix (diffs-as-data, account-level quota), and
less ready than assumed in the one place everyone believed was solved (the
transport, which does not exist at all). The task is worth doing and is not
over-engineered — but it is currently one label over three tasks' worth of work.
