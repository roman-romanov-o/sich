# Research: What Remote Support Exists Today

**Date:** 2026-07-16
**Status:** Complete

## Summary

A remote tmux card ships today and works as a **terminal**: ⌘⇧R opens an `ssh -t <target> tmux new-session -A -s <name>` PTY on the board. It is a
pixel-faithful remote terminal and nothing more — the card is invisible to every
other subsystem (hooks/state, persistence, quota, diffs, worktrees, the folder
picker). "Remote support" today means "you can see a remote tmux in a pane."

## Key Findings

1. **The command builder is real, pure, and unit-tested**
   - Evidence: `app/Sources/GhostlingCore/RemoteTmuxCommand.swift:103-119` builds
     `["/usr/bin/ssh", "-t", ("-p" port)?, ("-i" identity)?, target, remoteScript]`.
   - `remoteScript` (`:123-129`) = `tmux new-session -A -s '<session>' [-c '<dir>']`,
     shell-quoted (`:131-133`). Session names are sanitized of `.`/`:`/whitespace
     (`:97-100`).
   - `RemoteTmuxSpec.parse` (`:46-69`) accepts `[user@]host[:port]`.
   - Implication: the *transport primitive* is done and does not need rework.

2. **Entry point is a menu item only — not the create palette**
   - Evidence: `app/Sources/GhostlingApp/BoardShell.swift:563-566` — "New Remote
     tmux Session…", `keyEquivalent: "r"`, mask `[.command, .shift]`.
   - Handler `newRemoteTmuxMenuAction` (`:582-587`) → `promptRemoteTmux()`
     (`:591-626`), a **3-field `NSAlert`** (destination / tmux session / start dir).
   - Implication: the production task-creation surface (`CreateCardPalette`,
     ⌘N) has **no remote concept at all**. Remote is a side door with a raw
     text-field UX, not a first-class "where does this task run?" choice.

3. **Card creation deliberately skips every local-only step**
   - Evidence: `BoardShell.swift:1022-1036` `createRemoteTmuxSession` — compare to
     `createSession` (`:956-1014`). It skips: worktree provisioning, `startClaude`
     auto-type, `taskFolder` binding, and `rememberProjectDir`.
   - `projectDir` is set to `spec.target` (`BoardSeed.swift:117`) — i.e. the string
     `"roman@host"`, **not a path**. The comment concedes it is "a display/label
     field for a remote card (no local path)".
   - Implication: `projectDir` is overloaded as a label. Every consumer that treats
     `projectDir` as a real path (persistence/restore, folder joins) is wrong for
     remote cards. See doc 04.

4. **Firewall compliance is genuine, and already tested**
   - Evidence: `PoolFirewall.classify` (`app/Sources/GhostlingCore/PoolFirewall.swift:41-47`)
     only inspects `argv[0]`'s last path component for `claude`; for a remote card
     `argv[0] == "/usr/bin/ssh"`, so it classifies `.interactive` and passes.
   - Asserted at `app/Tests/GhostlingAppTests/RemoteTmuxCardTests.swift:32-37`.
   - ⚠️ **But note the firewall is structurally blind to the remote side.** The
     remote command string is `argv.last`, never parsed. `RemoteTmuxCommand` today
     only ever emits `tmux new-session`, so nothing is violated *in practice* — but
     if this task lets a user supply a remote command, `ssh host claude -p ...`
     would sail straight through. The firewall must be extended, not assumed.

5. **Test coverage is thin and deliberately non-networked**
   - Evidence: `RemoteTmuxCardTests.swift` has exactly 2 tests, both using the
     reserved `.invalid` TLD so ssh fails DNS immediately (`:11-13` docstring).
   - `app/Tests/GhostlingCoreTests/RemoteTmuxCommandTests.swift` exists but
     `grep -n "func test"` returns nothing — it uses swift-testing `@Test`, so
     coverage is there, but no test ever exercises a real ssh connection.
   - Implication: nothing in CI proves remote works end-to-end. That's the right
     call for tests, but it means the shipped feature's real-world behaviour is
     evidenced only by the user's manual use.

## Validated Assumptions

| Assumption | Status | Evidence |
|------------|--------|----------|
| ⌘⇧R SSHes into a box and attaches tmux (`new-session -A`) | ✅ Confirmed | `BoardShell.swift:563-566`, `RemoteTmuxCommand.swift:124` |
| It's watcher-compliant (local exec is `ssh`) | ✅ Confirmed, with a caveat | `PoolFirewall.swift:41-47`; firewall never inspects the remote command string (`RemoteTmuxCommand.swift:117`) |
| Remote card is a first-class board card | ⚠️ Partial | It appends to `cards` (`BoardShell.swift:1032`) and gets a pty (`:1033`), but carries no card-ID binding, no task folder, no real cwd |
| Card↔session join is by pty identity, not sessionID | ✅ Confirmed | `BoardShell.swift:358-363` — explicitly joins via `ptyByCard`, with a comment that a slug compare "would silently match nothing" |

## Gaps this task must close (evidence-backed)

| Capability | Local card | Remote card today |
|---|---|---|
| Terminal surface | ✅ | ✅ `RemoteTmuxCommand.swift:103` |
| Reachable from ⌘N create palette | ✅ | ❌ menu-only, `BoardShell.swift:563` |
| `GHOSTLING_CARD_ID` identity binding | ✅ `BoardSeed.swift:89` | ❌ absent from `remoteTmux` (`BoardSeed.swift:106-121`) |
| Hook-driven state (running/waiting/done) | ✅ | ❌ no transport (doc 02) |
| Turn diffs | ✅ | ❌ no transport (doc 02) |
| Survives app restart | ✅ `BoardShell.swift:391-420` | ❌ restores as a bogus **local** shell (doc 04) |
| Folder picker | ✅ NSOpenPanel `BoardShell.swift:920-928` | ❌ free-text field (`BoardShell.swift:610-612`) |
| Git worktree isolation | ✅ `WorktreeProvisioner.swift` | ❌ skipped by design (`BoardShell.swift:1017-1019`) |

## Open Questions

- Is the ⌘⇧R NSAlert flow something the user wants *kept* (a power-user escape
  hatch) or *replaced* by a host-aware create palette? This changes scope a lot.
- Does the user run one remote box or several? Nothing in the code models a
  "known hosts" list; `RemoteTmuxSpec` is constructed ad-hoc per invocation.
