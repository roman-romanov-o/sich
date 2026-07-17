# Task Description: Remote Sessions Reach the Board

**Task ID:** TASK-10a
**Status:** Draft
**Last Updated:** 2026-07-17

## Problem Statement

I want to run agent tasks on a remote machine (reached over ssh via Tailscale) and
have them behave on the board exactly like local ones — moving through columns,
raising attention when they need me, and showing turn diffs. I also want to pick
the working folder on that remote box without hand-typing a path every time.

### Current State

⌘⇧R already opens a working remote **terminal**: `RemoteTmuxCommand.argv` builds
`ssh -t [-p port] [-i id] <target> tmux new-session -A -s <name> [-c <dir>]`, and
`-A` means re-opening reconnects to the same running session. That part works and
is watcher-compliant — the local executable is `ssh`, and a human drives the
session interactively.

What does **not** exist is any path for the remote machine's telemetry to reach the
local board (research doc 02, reviewer-verified):

- The hook sink is a **local file tail** — `HookEventTail.poll()` opens
  `~/.ghostling/events.jsonl` with `FileHandle(forReadingFrom:)` and seeks from a
  stored offset. It is **not** a listener. The HTTP/sidecar wire was deliberately
  deleted (`pyproject.toml:1-8`); the only `NWListener` in the repo is
  `StaticFileServer.swift:14`, serving the LikeC4 pane.
- `HookInstaller.installGlobal` writes only the **local** home
  (`HookInstaller.swift:35-43`). Nothing installs hooks on a remote host.
- `grep -i tailscale` over `app/Sources` + `app/Tests` returns **zero hits**.

So a remote session is a terminal, never a card. It cannot move columns, cannot
raise attention, cannot show diffs. **That gap is this task.**

Two live bugs in the shipped remote path make this concrete (both confirmed by
code reading and independently re-verified by the reviewer; neither reproduced):

1. **The forwarder is macOS-only.** `HookInstaller.swift:142-144` gates its entire
   diff block on three `/usr/bin/plutil -extract` calls. On a Linux remote these
   fail, `$session`/`$cwd` come back empty, and turn diffs are **silently skipped**
   — while the raw append at `:140` still succeeds. State would flow; diffs would
   vanish with no error.
2. **A remote card restores as a bogus local shell.** `BoardSeed.swift:117` sets
   `projectDir: spec.target`, so the card persists `cwd = "roman@host"`.
   `SessionRegistry.swift:275-277` does `directoryExists(cwd) ? cwd : homeDirectory`,
   the check fails, and `reopenShell` (`:251-253`) launches a **local** `$SHELL` in
   `$HOME` — still titled `roman@host · agent`. `PaneSnapshot` has no host or
   command-override field, so the ssh argv is unrecoverable.

### Desired State

I open a card, choose a remote host and folder from the creation palette, run
`claude` in the tmux session, and watch the card go running → waiting → done on my
laptop — with diffs — from any of my remote boxes. When the connection to a host
drops, the board tells me so rather than showing me a stale card that looks alive.

## Success Criteria

1. [ ] A remote session's state transitions (running/waiting/done) appear on the
       correct local card, driven by hooks from the remote machine. Requires
       **DD-identity** (blocker) to be decidable — "correct card" is undefined
       until identity binding is settled.
2. [ ] Turn diffs from a remote session render in drill-in on a **GNU/Linux
       userland**, verified two ways, because neither alone is sufficient:
       (a) an automated fixture test that runs the forwarder under GNU
       coreutils semantics — no `plutil`, and `base64` wrapping at 76 columns;
       (b) one **human sign-off** run against a real Linux host, recorded here.
       Scope note: portability is broader than `plutil`. `/usr/bin/base64` is
       currently survived by luck (`tr -d '\n'`, `HookInstaller.swift:191`), not
       by design. A fixture that stubs only `plutil` catches none of that and
       does **not** satisfy this criterion.
3. [ ] Per-host hook-install state is derived from an **actual remote probe**
       (read back the remote `~/.claude/settings.json` / forwarder presence and
       version), **never** from a locally-cached "I ran installRemote once" flag
       — a cached flag is the silent-assumption failure this criterion exists to
       prevent, and it would satisfy any looser wording.
       State set: `installed` / `not-installed` / `stale-version` /
       `unknown (probe failed)`. `unknown` is a distinct, visible state, never
       collapsed into `installed`.
       Surface: named in DD-identity/UI so a test can dispatch a **real event**
       against it, per this repo's interaction-AC binding rule.
4. [ ] Sessions and diffs from two different hosts are namespaced and never
       conflated with each other or with local sessions.
5. [ ] A remote card survives app restart: it reconnects to the still-running
       remote tmux session rather than restoring as a local shell in `$HOME`
       (regression test for bug 2 — must be proven red before green).
6. [ ] **Transport-down is visible and never counterfeits liveness.**
       Trigger (set by DD-001): the per-host ssh transport process exits
       (detected immediately), **or** ssh keepalives fail
       (`ServerAliveInterval=15` × `ServerAliveCountMax=3` ⇒ ~45s worst case for a
       silent partition).
       **`N` (line-silence threshold) is retired, not assigned** — DD-001 rejects
       line silence as a trigger *in kind*, because a healthy agent thinking for
       two minutes is silent, so no `N` is both fast enough to be useful and safe
       enough to never mislabel a working agent. Keepalives measure the transport,
       which is what this criterion is actually about.
       Bound: **X = 5s** — affected cards reflect the state within one board poll
       cycle *of detection*. (`X` and detection latency are distinct; on the ssh-exit
       path there is no 45s at all.)
       Negative assertion (the load-bearing half): a card whose host is
       unreachable **must not** read `running` or `waiting`. It reads a distinct
       `unreachable` state. A test must assert the negative, not just that some
       flag flipped.
7. [ ] **A transport reconnect that re-sends already-seen lines produces no
       duplicate state events and no duplicate diffs.** Dedup is content-based;
       a byte cursor cannot satisfy this (see OQ2). Covers the failure criterion
       4 does not: same-host replay, not cross-host conflation.
8. [ ] Card creation offers remote as a first-class choice, including a per-host
       recents list of previously used folders.
9. [ ] No inbound listener is added, and no new remote binary is distributed.

## Scope

**Honest sizing:** this is research's 10a (items 1-6) **plus a reduced item 8**
(the palette stage + per-host recents), which research assigned to 10b — and, per
blocker #2 below, part of item 7. The recents list is a *cut* relative to a tree
browser, but an *addition* relative to research's 10a. Stated plainly so the
growth is a decision, not a drift.

- Making the hook forwarder portable to a GNU/Linux userland — dropping `plutil`,
  and auditing every other coreutils assumption (`base64` line-wrapping at
  minimum). Not "remove one call."
- `installRemote(host:)` — push the forwarder and patch the remote
  `~/.claude/settings.json`; surface probe-derived per-host install state.
- The `ssh <host> "tail -F ~/.ghostling/events.jsonl"` transport, with per-host
  supervision, reconnect, and content-based dedup.
- Host-namespacing observed sessions and diffs.
- Remote card identity binding (**DD-identity** — blocker).
- Fixing remote-card persistence/restore (bug 2) — decided together with the
  location model (**DD-location** — blocker).
- Per-host transport liveness, surfaced on the card.
- Folding remote into `CreateCardPalette` as a "where does this run?" stage, with
  a per-host **recents list**.
- Retiring the ⌘⇧R NSAlert **in the final phase, after the palette stage is
  proven** — see the sequencing note below.

**Sequencing constraint:** ⌘⇧R is currently 10a's *own demo path* — research
defines the 10a demo as "open ⌘⇧R, run `claude` in the tmux, watch the card go
running → waiting → done." Retiring it early would make unfinished palette UI a
hard prerequisite for demonstrating criteria 1, 2, and 5, coupling all the
transport work to a UI change. The NSAlert therefore survives until the palette
stage replaces it, and is removed last.

### Out of Scope

- **Remote quota** — cut. `UsageEndpointReader.swift:16-17` reads the
  account-level `GET /api/oauth/usage`, and both machines are on the same account,
  so remote usage **already** appears in the local gauge.
- **Remote worktrees** — cut (research doc 04 §4).
- **A full remote tree browser** — a recents list is ~10% of the cost and most of
  the value; it also sidesteps the ssh-latency UX problem entirely.
- **A remote agent/helper binary** — `ssh` + `tail` + `ls` does the job with zero
  remote install and no new trust surface. This is the premature-abstraction trap
  for this task.
- **A listener or HTTP wire for hooks** — reintroduces exactly what DD-002 deleted
  and would make the hook block on network I/O.

## Constraints

| Type | Constraint | Reason |
|------|------------|--------|
| Technical | No inbound listener; no connection inbound to the laptop | Preserves DD-002; the laptop roams, so it has no stable address to listen on |
| Technical | Hooks must never block on network I/O | The forwarder's "never slow the watched session" contract (`HookInstaller.swift:116-117`) |
| Technical | Remote forwarder must be POSIX — no `plutil`, no macOS assumptions | Remote hosts are **both** Linux and macOS |
| Technical | Reuse the existing ssh identity; no new auth or trust surface | It already works over Tailscale; adding a second credential path is unjustified |
| Technical | Watcher-not-spawner: never auto-run `claude -p`, locally or remotely. **This task must extend `PoolFirewall` to inspect the remote command when `argv[0]` is ssh** — see the enforcement note below | The pool-billing constraint. Today `PoolFirewall` gates `assertNoHeadlessFlag` behind `isClaude(argv.first)` (`PoolFirewall.swift:41-51`), so an `ssh` argv short-circuits the check entirely and `ssh host claude -p` passes clean. (Local `claude -p` **is** still caught — the check inspects the remainder *when* argv[0] is claude.) This task adds two new ssh-command-emitting call sites (`installRemote`, the tail transport), and nothing constrains their command strings. Without this extension the constraint is enforced by code review only — i.e. aspirational. Extending the firewall is small, testable, and the natural home |
| Technical | Honest degradation — never fabricate a value | The project's own rule (`UsageEndpointReader.swift:12-14`); it is why criterion 6 exists |
| Resource | No new dependencies | Existing project discipline |

## Dependencies

### Prerequisites

- [x] Remote tmux terminal (⌘⇧R) — shipped 2026-07-14
- [x] Hook forwarder + `HookEventTail` sink — shipped
- [x] Diffs shipped as data over the hook channel — shipped

### Blockers

All three resolved in `/saha:decide` on 2026-07-17 (Proposed, pending review).
Research flagged exactly these three; an earlier draft of this document escalated
only the first and quietly demoted the other two.

- [x] **DD-transport → [DD-001](design-decisions/DD-001-remote-hook-telemetry-transport.md).**
      Open Question 1. Chose option (c): an **in-memory relay** — remote lines are
      never written to the local `events.jsonl`. Host is stamped
      (`ghostling_host`) at ingestion, the only point where host provenance exists.
      Sets N and X for criterion 6 (below).
- [x] **DD-identity → [DD-002](design-decisions/DD-002-remote-card-identity-binding.md).**
      Open Question 3. `GHOSTLING_CARD_ID` rides the tmux pane's launch command
      (mirroring `BoardSeed.liveTerminal`), plus card-unique session names with
      `(host, sanitized name)` uniqueness enforced across cards. Zero read-side
      change; no tmux version floor.
- [x] **DD-location → [DD-003](design-decisions/DD-003-location-model-and-remote-restore.md).**
      Open Question 4. Persist the argv/host the seed **already carries**
      (`PaneSnapshot` v1→v2) and host-qualify the recents store. The full
      `SessionLocation` enum (research's **L** item) is **out of scope**; reversal
      is mechanical.

## Technical Context

Research: 6 documents in `research/`, reviewed and verified — all four
load-bearing claims confirmed against source, no blockers.

**Chosen transport:** a per-host `ssh <host> "tail -F ~/.ghostling/events.jsonl"`
forwarder feeding the local sink. It reuses the ssh identity already in use, adds
no listener, requires no inbound connection to a roaming laptop, and keeps DD-002
intact. Rejected alternatives: reverse tunnel + listener (regresses DD-002, blocks
the hook on network I/O), a Tailscale-bound listener, and sshfs (vnode watches do
not work over a network filesystem).

**Research's "highest-value finding" was over-read — see DD-002 (2026-07-17).**
It read: *"`tmux new-session -A` on attach inherits the original session's
environment — which invalidates the obvious `GHOSTLING_CARD_ID` identity fix
before anyone builds it."* Inherited environment is stale **only when a session
name is reused by a different card**. With card-unique session names, the original
session's `GHOSTLING_CARD_ID` *is* the correct one, and inheritance on attach is
right rather than wrong.

The collision that made it look fatal (`sanitizeSessionName` is lossy; the name is
free text; blank input defaults **every** card to the literal `"ghostling"`) is a
**card-modeling bug, not an identity bug**: two cards named `ghostling` on one host
genuinely *are* one tmux session, because `-A` attaches. So `GHOSTLING_CARD_ID`
riding the pane's launch command — exactly as `BoardSeed.liveTerminal` already does
locally — is the chosen mechanism, with zero read-side change.

### Affected Components

- `HookInstaller.swift` — portability (`:142-144`); new `installRemote(host:)`
- `HookEventTail.swift` — sink; the write-path fork lands here or upstream of it
- `SessionRegistry.swift` — `resolveCwd` (`:275-277`), `reopenShell` (`:251-253`),
  `snapshotWindows` / `PaneSnapshot` ctor (`:91-98`)
- `BoardSeed.swift` — `projectDir: spec.target` (`:117`)
- `PaneSnapshot` (`SessionSnapshot.swift:41-80`) — has `cardID`/`title`/
  `taskFolder`/`claudeSessionID`/`cardState`/`wasAlive` and **no** host or argv
  field; needs one to restore the ssh command (DD-location)
- `CreateCardPalette.swift` — the `browse` seam (`:335`); `PaletteProject`
  (`:5-10`, local-FS assumption); new remote stage
- `BoardShell.swift` — `chooseFolder` NSOpenPanel (`:920`); recents store
  (`:984-1002`); ⌘⇧R NSAlert / `promptRemoteTmux` (`:591-626`), retired last
- `HookSessionStore` / the reconciler — where state coalescing actually happens
- `SessionsFeed.swift` — `TurnDiffNormalizer`, the separate diff path (`:44-46`)
- `PoolFirewall.swift` (`:41-51`) — must learn to inspect ssh remote commands

### Anti-patterns to avoid

- **Do not build in `FolderPicker.swift`.** `FolderPickerView`/`FolderRow`/
  `RecentFolder` are **dead production code** — referenced only by their own tests.
  (`SahaTaskChooserView` in the same file *is* live, via `BoardShell.swift:28,1085`.)
  Building there ships green-but-unreachable code — the exact
  `saha-creation-had-no-ui-entry-point` trap.
- **Do not assume the Python sidecar exists.** It is retired.
- **Do not trust `docs/tasks/task-05-turn-diffs/task-description.md:28`**
  ("remote sessions already reach the board over the tailscale channel"). It is
  **false** and has sat unchallenged in the docs.

## Open Questions

**All four resolved 2026-07-17 by DD-001/002/003** (see Blockers above). Retained
below as the record of what was asked and why — the reasoning is still load-bearing
for `/saha:plan`, and two of these framings turned out to be wrong in instructive
ways (noted inline).

- [x] **1. The write-path fork → [DD-001](design-decisions/DD-001-remote-hook-telemetry-transport.md).**
      **Answered: option (c).** The framing below treats the rotation collision as a
      cost every option pays. It is not — it is *created* by writing remote lines to
      the local file (remote-only work fires no local hook, so nothing ever rotates
      it) and is **absent** from the relay, which leaves the local file with exactly
      one writer and one rotator, as today. The decisive argument turned out to be
      different from either option's framing: the hook payload has **no hostname
      field**, so appending remote lines into the shared file destroys host
      provenance irreversibly and makes criterion 4 unachievable.
      Original framing follows. Appending remote lines
      into the local `events.jsonl` risks colliding with the forwarder's own
      5 MiB rotation (`mv -f "$file" "$file.1"`, `HookInstaller.swift:220-222`).
      **Three** options, not two:
      (a) a local appender holding a long-lived fd — this is the one that breaks:
          the fd keeps writing into the renamed file, and remote lines silently
          vanish;
      (b) **reopen-per-append** (`O_APPEND`, reopened per batch) — this is
          precisely why the existing forwarder is rotation-safe (`>> "$file"`,
          `:140`), and it sidesteps the renamed-file problem entirely;
      (c) feed `HookEventTail` directly, bypassing the file.
      Note the failure in (a) is a consequence of an *implementation choice*, not
      a property of the file. Correction to an earlier framing: `HookEventTail`
      does **not** "follow an inode" — `resolveStart` resolves by **path** each
      `poll()` and resets the offset to 0 on inode change.
- [x] **2. Dedup must be content-based → [DD-001](design-decisions/DD-001-remote-hook-telemetry-transport.md).**
      **Answered: confirmed content-based**, `tail -n 200 -F` replay window. The
      reconciler investigation below is still required at implementation time —
      `turn_diff` rides a separate path and needs an explicit content key.
      Original framing follows. A per-host **byte**
      cursor has no inode analogue over `tail` stdout, so it cannot survive remote
      rotation or a `tail -n +1` reconnect. Now bound to criterion 7.
      **Investigate the reconciler, not `SessionsFeed`:** an earlier draft cited
      `SessionsFeed.swift:36-41` as "state coalescing," but those lines are a
      *comment* stating that coalescing happens in the **reconciler**
      (`HookSessionStore` rank / no-flicker write). Confirm there whether a
      replayed `turn_diff` dedups — it rides a separate path (`:44-46`).
- [x] **3. Remote card identity binding → [DD-002](design-decisions/DD-002-remote-card-identity-binding.md).**
      **Answered — and the premise below is wrong.** `tmux -A` env inheritance does
      **not** kill the `GHOSTLING_CARD_ID` approach; it only makes it unsafe under
      **session-name reuse across different cards**. Card-unique names make the
      inherited value correct, so the chosen mechanism *is* `GHOSTLING_CARD_ID`,
      carried on the pane's launch command exactly as `BoardSeed.liveTerminal` does
      locally. Rejected: `new-session -e` (needs tmux ≥ 3.2 — verified in tmux
      CHANGES; Ubuntu 20.04 ships 3.0a, Debian 11 ships 3.1c, and remote OS is
      "both/varies"); deriving identity from `tmux display-message` at hook time
      (`$TMUX`-in-hook is **unverified**, would need a spike, and forces a read-side
      rewrite); `ssh SendEnv` (needs remote `AcceptEnv`, silently dropped when
      absent).
- [x] **4. The location model → [DD-003](design-decisions/DD-003-location-model-and-remote-restore.md).**
      **Answered: all three surfaces, narrowly.** `PaneSnapshot` gains a structured
      `remote: RemoteSpecSnapshot?` — the *spec* (`{host, user?, sessionName, port?,
      identityFile?, remoteDir?}`), **not** the argv — and needs **no version bump**
      (optional fields decode nil, per the `claudeSessionID` precedent; a bump would
      *discard* every existing pane, since `SessionSnapshot.swift:11-13` ignores a
      version mismatch rather than migrating). Restore rebuilds the command via the
      same `RemoteTmuxCommand.argv(for:)` constructor the create path uses, so the
      persisted shape still **cannot name a command** — the watcher invariant stays
      where `SessionSnapshot.swift:6-9` puts it, in the shape. (An earlier draft here
      said `host: String?` + `commandOverride: [String]?` at version 1 → 2; that was
      rejected in review — it would have let a snapshot express `claude -p`.) The bare
      `[String]` recents become a `Codable` `{host: String?, path: String}`;
      `PaletteProject` gains the same optional host. The full `SessionLocation`
      enum (research doc 05's **L** item) is **rejected** — the recents-only picker
      answer removed the need it was sized for, and reversal is mechanical. The
      framing below is otherwise still accurate. Original framing follows.
      Partly answered already,
      and the answer is **not** the cheap branch: the palette's recents are a
      *separate* model from `PaneSnapshot`. `PaletteProject`
      (`CreateCardPalette.swift:5-10`) is `{ path: String, activeCards: Int }` and
      displays via `abbreviatingWithTildeInPath` — a local-FS assumption. Recents
      are a bare `[String]` in `UserDefaults` (`ghostling.recentProjectDirs`,
      `BoardShell.swift:984-1002`), capped at 6, seeded with the local repo root.
      A **per-host** recents list needs host-awareness threaded through
      `PaletteProject`, `recentProjectDirs()`, `rememberProjectDir()`, and the
      UserDefaults schema — *independent of* whatever bug 2's snapshot fix does.
      So the real question for DD-location is not "small or large" but "how much
      of item 7," covering `PaneSnapshot`, `PaletteProject`, and the recents store
      as one decision.

## Decisions Taken (2026-07-17)

| Question | Answer | Consequence |
|---|---|---|
| Remote OS? | **Both Linux and macOS** | `plutil` fix is required in the core slice, not deferred hardening |
| Same Anthropic account? | **Yes** | Remote quota cut entirely — already works |
| How many hosts? | **A few (2-5)** | Per-host cursors, supervision, and namespacing are real, in-scope work |
| Picker depth? | **Recents list, not a tree browser** | Removes the transport+latency problem; may remove the **L** refactor (Q4) |
| ⌘⇧R NSAlert? | **Fold into `CreateCardPalette`, retire the NSAlert** | One creation path; the recents list lives where folders are already chosen |

## References

- `research/README.md` — index, headline conclusions, corrected memory notes
- `research/01-existing-remote-support.md` — what ⌘⇧R gives today
- `research/02-hook-telemetry-transport.md` — **the central risk**
- `research/03-remote-file-picker.md` — picker options; the dead-view finding
- `research/04-quota-persistence-diffs-worktrees.md` — why quota/worktrees are cut
- `research/05-critical-assessment.md` — scoping verdict
- **TASK-10b (deferred):** a full remote tree browser, if the recents list proves
  insufficient in practice.
