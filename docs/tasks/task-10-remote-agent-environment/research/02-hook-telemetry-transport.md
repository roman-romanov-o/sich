# Research: Hook/Telemetry Path from Remote → Local App

**Date:** 2026-07-16
**Status:** Complete — **this is the central architectural risk**

## Summary

There is **no remote→local telemetry channel today, of any kind**. The hook sink
is a plain **local append-only file** (`~/.ghostling/events.jsonl`) that the app
tails with a file watcher. A Claude session on a remote box writes to the
*remote* `~/.ghostling/events.jsonl`, which the local app never sees. Remote
cards are therefore **permanently `.idle`** on the board — they never move
columns, never show attention, and never produce diffs. Fixing this is the task.

## Key Findings

1. **The sink is a file, not a server. There is no port, no HTTP, no sidecar.**
   - Evidence: `app/Sources/GhostlingApp/HookInstaller.swift:126` — the forwarder
     writes `file="${GHOSTLING_EVENTS_FILE:-$HOME/.ghostling/events.jsonl}"`;
     `:140` `printf '%s\n' "$line" >> "$file"`.
   - Reader: `app/Sources/GhostlingApp/SessionsFeed.swift:103-111` resolves the same
     path; `app/Sources/GhostlingCore/HookEventTail.swift:36-48` opens it with
     `FileHandle(forReadingFrom:)` and seeks from a persisted byte offset.
   - The forwarder docstring is explicit (`HookInstaller.swift:112-113`): "the app
     tails that file (no server, no port, no reply)."
   - **The Python sidecar is retired.** Evidence: `pyproject.toml:1-8` — "The Python
     mission-control sidecar was retired in the Phase-03 cutover… no Python runtime,
     no localhost sidecar, no HTTP wire (DD-001/DD-002)." The only Python left in the
     repo is `tests/unit/test_forward_rotation.py`.
   - ⚠️ **This corrects the stale memory note** that a Python sidecar exists and
     could be deployed remotely. It does not exist. There is nothing to deploy.

2. **`HookInstaller.installGlobal` only ever writes the LOCAL home.**
   - Evidence: `HookInstaller.swift:35-43` — `home: URL = FileManager.default.homeDirectoryForCurrentUser`,
     writes `~/.ghostling/ghostling-forward.sh` and `~/.claude/settings.json`.
   - Implication: nothing installs hooks on the remote box. Even the *emitting*
     half of the pipeline is absent remotely, before we get to transport.

3. **The forwarder script is macOS-only and will break on a Linux box.**
   - Evidence: `HookInstaller.swift:142-143` and `:191`, `:204`, `:207` call
     `/usr/bin/plutil` (to extract JSON fields) and `/usr/bin/base64`.
   - `plutil` **does not exist on Linux**. On a Linux remote, every `plutil` call
     fails → `event`/`session`/`cwd` are empty → the whole diff block at `:145` is
     skipped. The raw line still appends (`:140`), so basic state *would* survive,
     but **turn diffs would not**.
   - `base64` is at `/usr/bin/base64` on both macOS and most Linux distros, but the
     GNU version wraps at 76 cols by default — the script already pipes through
     `tr -d '\n'` (`:191`), so that's handled by luck rather than design.
   - Implication: a "just install the same forwarder remotely" plan **does not
     work as-is**. The script needs a portable JSON extractor (`python3 -c`, `jq`,
     or pure-shell parsing) before it can run on the target box. This is concrete,
     cheap, and easy to miss.

4. **The consumer side is transport-agnostic and genuinely remote-ready.**
   - Evidence: `SessionsFeed.swift:44-49` normalizes lines; `HookEventTail.poll()`
     returns whole lines from a byte offset. Nothing in the reader path cares
     *where* a line came from.
   - Implication: **whatever transport we pick only has to get remote lines into
     the local events file (or an equivalent `Data` stream).** The board, the
     reconciler, and the diff view need zero changes. This is the one genuinely
     good piece of news — the DD-002 file-sink design bought us this.

5. **Diffs are already data-only. The task-05 design holds; its assumption did not.**
   - Evidence: `app/Sources/GhostlingCore/DiffModel.swift:143-155` parses
     `ghostling_event_type == "turn_diff"` with `diff_base64` / `cwd_base64`.
     `grep -rn "/usr/bin/git" app/Sources` returns **only**
     `WorktreeProvisioner.swift:38` — the app **never shells out to git to render a
     diff**. The diff is computed by the hook where the repo lives (`HookInstaller.swift:180`)
     and shipped as base64 in the event line.
   - ⚠️ **But `docs/tasks/task-05-turn-diffs/task-description.md:28` states remote
     "sessions already reach the board over the tailscale channel." That is FALSE.**
     No such channel exists anywhere in the codebase. Task-05's diff *shape* is
     remote-ready; its stated premise about transport was never true.
   - Implication: once lines arrive, remote diffs work for free (modulo the `plutil`
     bug in #3). This is a real asset — don't rebuild it.

## Validated Assumptions

| Assumption | Status | Evidence |
|---|---|---|
| Agent state detection is via hooks, not terminal scraping | ✅ Confirmed | `SessionsFeed.swift:1-11`, `HookSessionStore` |
| The hook receiver is a local HTTP/socket listener | ❌ **Incorrect** | It's a file tail — `HookEventTail.swift:36`; `pyproject.toml:1-8` says the HTTP wire was deliberately removed |
| Anything reaches the receiver over Tailscale today | ❌ **Incorrect** | `grep -i tailscale` over `*.swift`/`*.sh` returns **zero** hits; only prose in task-05 docs |
| Diffs ship as data over the hook channel, remote-free | ⚠️ Partial | Shape ✅ (`DiffModel.swift:143`); transport ❌ (no channel); Linux ❌ (`plutil`, `HookInstaller.swift:142`) |
| The Python sidecar exists and could be deployed remotely | ❌ **Incorrect** | Retired — `pyproject.toml:1-8` |

## Transport Options (concrete, with trust/auth analysis)

The requirement reduces to: **get newline-delimited JSON from the remote box's
hook script into the local `~/.ghostling/events.jsonl`.** Ranked.

### Option A — `ssh` tail-forwarder process per host (recommended)
Local app spawns one long-lived `ssh <host> "tail -n +1 -F ~/.ghostling/events.jsonl"`
and appends stdout to the local events file (or feeds `HookEventTail` directly).
- **Auth/trust:** reuses the user's existing ssh identity + `known_hosts`. **No new
  trust surface, no listener, no port, no token.** Tailscale already secures the
  path; we inherit it and add nothing.
- **Watcher discipline:** ✅ the spawned binary is `ssh`; `tail` is read-only and
  spawns nothing. Passes `PoolFirewall` for the same reason ⌘⇧R does.
- **Pros:** simplest; symmetric with the existing ⌘⇧R design (ssh is already the
  sanctioned remote primitive); works over Tailscale/any ssh reachability; no
  inbound connection to the laptop (critical — a laptop roams and NATs).
- **Cons:** one persistent ssh process per host (cheap, but must be supervised —
  reconnect on drop with backoff); `tail -F` restarts re-send from the offset we
  choose, so **de-dup/offset bookkeeping must be per-host**. `HookEventTail`'s
  offset is keyed to one file+inode (`HookEventTail.swift:55-76`) — appending remote
  lines into the *same* local file avoids touching that logic entirely, at the cost
  of needing a separate "how far have I tailed host X" cursor.
- **Cost:** low. This is the answer unless something rules it out.

### Option B — reverse ssh tunnel + local listener
Remote hook `curl`s to a port tunnelled back via `ssh -R`.
- **Auth/trust:** the tunnel is authenticated, but we'd bind a listener and
  reintroduce **exactly the HTTP wire DD-002 deliberately deleted** (`pyproject.toml:1-8`).
- **Cons:** regresses a decided architecture; adds a port; hook now blocks on
  network I/O — the forwarder's design contract is "never block the watched
  session" (`HookInstaller.swift:116-117`). A hung curl would stall the agent.
- **Verdict:** reject.

### Option C — Tailscale-addressable listener on the laptop
Remote hook posts to the laptop's Tailscale IP.
- **Auth/trust:** Tailscale ACLs are real auth, and the laptop's tailnet IP is
  stable (unlike its LAN IP). Better than B.
- **Cons:** still a listener (against DD-002); still blocks the hook; **hard
  dependency on Tailscale specifically**, whereas Option A works over any ssh. The
  user *currently* uses Tailscale — that's a fact about today, not a constraint to
  bake in.
- **Verdict:** reject unless A proves unworkable.

### Option D — polling over ssh (`ssh host "cat --bytes=+N file"`)
- Same trust story as A, but higher latency + a process per poll. A's `tail -F` is
  strictly better. **Reject** — A is the same idea done properly.

### Option E — remote store-and-forward via the sshfs/mount
- Mounting the remote `~/.ghostling` locally and letting `FileWatcher` watch it.
- **Cons:** `FileWatcher` uses `DispatchSource.makeFileSystemObjectSource` with a
  vnode watch (`app/Sources/GhostlingApp/FileWatcher.swift:35-37`). **Vnode watches
  are unreliable-to-nonfunctional over network filesystems** — the kernel can't see
  a remote writer. The 3s backstop `Timer` (`SessionsFeed.swift`) would carry it,
  degrading to polling anyway. Adds a mount dependency for no gain. **Reject.**

## Risks Identified

1. **Remote forwarder is not portable** (Severity: **High**, cheap to fix)
   - `plutil` (`HookInstaller.swift:142-143`) is macOS-only → silently no diffs on a
     Linux box. `installGlobal` (`:35`) can't target a remote home at all.
   - Mitigation: make the forwarder POSIX/portable *before* wiring transport, and
     add a `installRemote(host:)` that scp/heredocs the script + patches the remote
     `~/.claude/settings.json`. Prove it with a Linux-shaped fixture test.

2. **Bootstrapping the remote box is an unsolved, user-visible step** (Severity: High)
   - Nothing installs anything remotely today. Someone must put the forwarder and
     the settings.json entry on the far side. Silent failure mode: the card opens,
     the terminal works, and the board just never updates — indistinguishable from
     "the agent is idle." **This is the exact "green but unreachable" trap this
     project has hit repeatedly** (see `saha-creation-had-no-ui-entry-point`,
     `board-status-bug-was-missing-global-hooks` — the latter was *literally this
     bug*, locally).
   - Mitigation: an explicit, visible per-host "hooks installed / not installed"
     state on the card, plus a one-click install. Never fail silently.

3. **Identity binding is absent for remote cards** (Severity: High)
   - `GHOSTLING_CARD_ID` rides the pty env locally (`BoardSeed.swift:89`) and is
     stamped onto hook lines by the forwarder (`HookInstaller.swift:135-139`).
     `BoardSeed.remoteTmux` (`:106-121`) mints a `cardID` but **never injects it into
     the ssh command**. Worse: even if it did, **`ssh` does not forward environment
     variables by default** (needs `SendEnv` locally + `AcceptEnv` in the remote
     `sshd_config`), and **`tmux new-session -A` attaching to an existing session
     inherits the ORIGINAL session's environment, not the new client's** — so an env
     var is the wrong mechanism here regardless.
   - Mitigation: bind by `(host, remote-cwd)` or pass the card id *inside* the
     remote command (e.g. `tmux new-session -A -s x -e GHOSTLING_CARD_ID=…`, which
     tmux ≥3.2 supports for *created* sessions only — still not for attach). This
     needs a real design decision, not a tweak. **Flag for `/saha:decide`.**

4. **Multi-host de-dup / ordering** (Severity: Medium)
   - `HookSessionStore` reconciles by `session_id`. Two boxes can produce colliding
     `cwd` values (`/home/roman/project` on both) and the reconciler's dir-join
     (`SessionsFeed.swift:24` labels by `projectDir`) has no host dimension.
   - Mitigation: namespace observed sessions by host at ingest.

5. **`tail -F` + rotation interaction** (Severity: Low-Medium)
   - The forwarder rotates at 5 MiB (`HookInstaller.swift:220-223`, `mv -f "$file" "$file.1"`).
     `tail -F` (capital F) follows by name and handles this. `tail -f` does not.
     Use `-F`, and note GNU vs BSD `tail` both support it.

## Open Questions

- Is the remote box macOS or Linux? Decides how urgent the `plutil` fix is.
  **Cannot verify from the repo — must ask the user.**
- Does the user want *multiple* remote hosts, or one? Multi-host makes per-host
  cursor/supervision real work; single-host makes Option A nearly trivial.
- Does the remote `sshd` permit long-lived connections / is there a keepalive
  requirement over Tailscale? Not verifiable here.
