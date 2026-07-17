# Research — TASK-10: Remote Agent Environment

**Date:** 2026-07-16
**Status:** Complete
**Task intent (verbatim from the user):** "I wanna be able to run tasks in remote
env (right now I'm using ssh via tailscale). We should also have file picker there
(in remote env)."

## Contents

| File | Covers |
|---|---|
| [`01-existing-remote-support.md`](01-existing-remote-support.md) | What the ⌘⇧R remote tmux card actually does today — files, entry points, firewall compliance, test coverage, and the capability gap vs. a local card |
| [`02-hook-telemetry-transport.md`](02-hook-telemetry-transport.md) | **The central risk.** How hook events reach the app (a file tail, not a listener), why nothing reaches it from a remote box today, and 5 ranked transport options with trust/auth analysis |
| [`03-remote-file-picker.md`](03-remote-file-picker.md) | Where the real picker lives (not `FolderPicker.swift`), why `NSOpenPanel` can't go remote, and 4 options for a remote directory source |
| [`04-quota-persistence-diffs-worktrees.md`](04-quota-persistence-diffs-worktrees.md) | Quota (mostly a non-problem), persistence/identity (actively broken), diffs (remote-ready in shape), worktrees (hard-local — cut) |
| [`05-critical-assessment.md`](05-critical-assessment.md) | Is the task well-scoped? What to cut, what to split, what to ask the user. **Read this one first if short on time.** |

## Headline conclusions

1. **The transport does not exist.** Remote cards are permanently `.idle` — no hook
   events can reach the local app from a remote box. Closing that gap *is* the task.
   Recommended: a per-host `ssh <host> "tail -n +1 -F ~/.ghostling/events.jsonl"`
   forwarder (doc 02, Option A). No listener, no new trust surface, no inbound
   connection to a roaming laptop.
2. **Cut remote quota and remote worktrees.** Quota is account-level and read from
   a server endpoint — same-account remote usage *already* shows in the local gauge
   (doc 04 §1). Worktrees are already skipped by design (doc 04 §4).
3. **Two live bugs found, neither previously flagged:** the hook forwarder is
   macOS-only (`/usr/bin/plutil`), so a Linux remote would ship state but silently
   no diffs; and a remote card restores as a bogus **local** shell at `$HOME`
   (doc 04 §2).
4. **Split into 10a (remote sessions reach the board) and 10b (remote picker).**
   Transport before picker — a picker that creates a card the board can't observe is
   worse than no picker.

## Stale memory notes corrected by this research

| Claim | Verdict |
|---|---|
| The hook receiver is a local HTTP/socket listener | ❌ It's a **file tail** (`HookEventTail.swift`); the HTTP wire was deleted — `pyproject.toml:1-8` |
| The Python sidecar exists / could be deployed remotely | ❌ **Retired.** Nothing to deploy |
| Something reaches the board over the Tailscale channel today | ❌ **Zero** `tailscale` references in code; `docs/tasks/task-05-turn-diffs/task-description.md:28` is false |
| The folder picker is `FolderPicker.swift` (NSOpenPanel) | ❌ That view is **dead production code**; the real picker is `CreateCardPalette` + `BoardShell.chooseFolder` |
| Remote cards survive restart / reconnect to the running tmux | ❌ **Broken** — restores a local `$SHELL` at `$HOME` |
| ⌘⇧R remote tmux card ships (`ssh -t` + `tmux new-session -A`) | ✅ Confirmed |
| Watcher-compliant (local exec is `ssh`) | ✅ Confirmed, with a caveat: the firewall never inspects the remote command string |
| Card↔session join is by pty identity, not sessionID | ✅ Confirmed |
| Diffs are git-sourced, shipped as data | ✅ Shape confirmed; transport still missing, and the producer is macOS-only |

## Questions for the user (block planning)

1. Is the remote box **Linux or macOS**? (decides `plutil` urgency)
2. **Same Anthropic account** on both machines? (decides whether quota is truly out of scope)
3. **One remote host or several**? (decides per-host cursor/supervision complexity)
4. **Tree browser or a remote-recents list**? (biggest scope lever in the task)
5. Keep or retire the ⌘⇧R `NSAlert` in favour of a host-aware create palette?
