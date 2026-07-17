# DD-001: Remote Hook Telemetry Transport

**Status:** Proposed
**Date:** 2026-07-17
**Deciders:** Roman Romanov (product), planning session
**Resolves:** task-description.md blocker **DD-transport**

## Context

Today there is **no remote→local telemetry path at all**. `⌘⇧R` gives a remote
*terminal* (`ssh -t <target> tmux new-session -A -s <name>`), but never a remote
*card*: it cannot move columns, raise attention, or show turn diffs. The hook sink
is a **local file tail** (`HookEventTail.poll()` — open by path, `fstat` for inode,
seek to a saved offset), not a listener. `HookInstaller.installGlobal` writes only
the local `~/.claude/settings.json`. `grep -i tailscale` over `app/` returns zero
hits.

Closing that gap needs a decision on **how remote hook lines reach the local
normalizer**, because the obvious answer (append them into the local
`~/.ghostling/events.jsonl` and let the existing tail pick them up) has two
non-obvious failure modes discovered during research.

### Constraints

- **DD-002 of task-03 (observe-only file sink) must not regress.** No server, no
  port, no reply, no listener. The HTTP/sidecar wire was deliberately deleted;
  `pyproject.toml` is gutted and the Python sidecar is retired.
- **The forwarder must never block the watched session.** Its stated contract
  (the forwarder's never-block contract comment) is "never spawns anything, never reads back,
  never blocks". Network I/O inside a hook violates this.
- **No inbound connection to a roaming laptop.** The local machine moves between
  networks; it cannot host a reachable endpoint.
- **No new remote binary.** This project has no cross-compiled distribution
  pipeline (research doc 05, anti-pattern 4). `ssh` + `tail` must suffice.
- **The hook payload carries no host field.** `session_id`, `timestamp`, `cwd`,
  `hook_event_name`, `tool_name` — and nothing else. Zero grep hits for
  `hostname`. Host provenance does **not** exist in the data.
- Remote OS **varies** (Linux and macOS) — user answer, 2026-07-16.
- Host count is **2-5** — user answer, 2026-07-16.

### Requirements

- Satisfies success criteria **4** (namespaced by host, never conflated),
  **6** (transport-down visible, never counterfeits liveness), **7** (reconnect
  replay produces no duplicate events or diffs), and **9** (no inbound listener,
  no new remote binary).
- Must define criterion 6's trigger and latency bound concretely enough that a
  test can dispatch a real event against it.

## The two findings that drive this decision

**Finding 1 — host provenance is destroyed by merging.** Because no hook line
carries a hostname, the *only* place host attribution exists is the transport
itself: the app knows which host it opened an ssh channel to. If remote lines are
appended **verbatim** into the shared local `events.jsonl`, that knowledge is thrown
away at the moment of the append and cannot be recovered downstream.

**Stated precisely** (the first draft overstated this): Option 1 does not make
criterion 4 *unachievable* — an appending transport could stamp `ghostling_host`
before writing, exactly as the relay does, and Option 1's own con concedes this.
What it means is that **Option 1 must do the stamping too**, at which point its
sole claimed advantage over the relay — "the lines are just the same lines" —
evaporates. The choice is not stamp-vs-can't-stamp; it is where the stamped line
lands.

This is not hypothetical. `BoardShell.applySessions` joins observed sessions to
cards by directory when the directory is unambiguous. A remote macOS host with a
checkout at `/Users/roman/proj` and a local card at `/Users/roman/proj` produce
**byte-identical `cwd` values**. Without host qualification, a remote session
would move a local card. Since the user's remote OS answer was "both/varies",
this path is live, not theoretical.

**Finding 2 — rotation ownership.** *(Corrected after review: an earlier draft
framed this as "revising a research claim that rotation is a cost whichever
transport wins." Research made no such claim — `research/02-hook-telemetry-transport.md`
risk 5 says the opposite, that `tail -F` follows by name and handles rotation. The
observation below stands on its own; the rebuttal it was dressed in was aimed at
nobody. It is also not decisive — Finding 1 is.)*

Rotation happens *only inside the forwarder*,
on each hook invocation (the forwarder's rotation block, `mv -f "$file" "$file.1"`
past 5 MiB). If remote lines were appended into the local file, then a
remote-only working session would grow that file without bound — no local hook
fires, so nothing ever rotates it. Appending would also fork the write path: a
long-lived append fd keeps writing into the *renamed* file after a rotation, and
those lines vanish silently.

Both findings point the same way: **the local `events.jsonl` is the wrong place to
put remote lines.**

## Options Considered

### Option 1: Append remote lines into the local `~/.ghostling/events.jsonl`

**Description:** Per-host `ssh <host> tail -F ~/.ghostling/events.jsonl`; the app
appends each received line to the local events file; the existing `HookEventTail`
picks them up with no read-path change.

**Pros:**
- Single ingestion point; zero change to `HookEventTail`, normalizer, or store.
- Lines survive an app restart in the local file.

**Cons:**
- **Destroys host provenance** (Finding 1) unless each line is rewritten on the
  way in — at which point the "no read-path change" benefit is already gone.
- **Inherits the rotation fork** (Finding 2): needs reopen-per-append *and* a new
  owner for rotation, since remote-only work never triggers the forwarder's own
  `mv`.
- The durability benefit is **illusory**. The app is the tailer; if the app is
  closed, nothing is receiving lines to append. The remote's own `events.jsonl`
  is already the durable store. This duplicates a log for no gain.
- Writes a second producer into a file whose only writer today is the forwarder,
  breaking a simple invariant for nothing.

**Effort:** Medium (rotation ownership + reopen-per-append + provenance stamping).

### Option 2: In-memory relay — stamp host at ingestion, feed the normalizer directly

**Description:** One supervised `ssh` child per host running
`tail -n <N> -F ~/.ghostling/events.jsonl`. The app reads its stdout line-by-line,
stamps `"ghostling_host":"<host>"` onto each JSON line at ingestion (the same
splice the forwarder already does for `ghostling_card_id`), and feeds the result
into the same normalizer that `HookEventTail.poll()` feeds. Remote lines never
touch local disk.

**Pros:**
- **Host provenance is captured at the only point where it exists** — the channel
  the line arrived on. Criterion 4 becomes structurally satisfiable.
- **Dissolves the rotation problem rather than solving it.** The local file keeps
  exactly one writer (the local forwarder), which rotates it on every local hook
  exactly as today. Nothing about local behaviour changes.
- `tail -F` (`--follow=name --retry`) is *precisely* correct against the remote
  forwarder's `mv`-based rotation — it re-opens by name. The existing rotation
  design and the transport agree by construction.
- Transport liveness is a first-class object: the ssh child's exit **is** the
  down signal (criterion 6), with no extra machinery.
- No listener, no port, no remote binary, no inbound connection. DD-002 intact.
- Reuses the existing ssh identity/Tailscale reachability the user already has.

**Cons:**
- Lines received while the app is closed are not replayed beyond `tail -n <N>`.
- Adds a per-host supervised child process to manage (retry/backoff).
- Two ingestion paths into the normalizer (file tail + relay) instead of one.

**Effort:** Medium.

### Option 3: Reverse tunnel + local listener

**Description:** `ssh -R` a port to the laptop; the remote forwarder POSTs hook
lines to it.

**Pros:**
- Push-based; no polling; lowest latency.

**Cons:**
- **Regresses task-03 DD-002 directly** — reintroduces exactly the listener that
  was deliberately deleted.
- Makes the hook **block on network I/O**, violating the forwarder's core
  contract. A stalled tunnel would slow the user's actual agent session.
- Fails the roaming-laptop constraint.

**Effort:** High. **Rejected on constraint, not cost.**

### Option 4: sshfs / network mount + existing tail

**Description:** Mount the remote `~/.ghostling` locally; point `HookEventTail` at it.

**Pros:**
- Literally zero new code.

**Cons:**
- `HookEventTail`'s inode-based checkpoint has no meaning across a network FS.
- vnode/`fstat` semantics over sshfs are unreliable; rotation detection breaks.
- Adds a userspace FS dependency to a user's machine for a log tail.

**Effort:** Low to try, high to trust. **Rejected.**

## Decision

**Chosen Option:** **Option 2 — in-memory relay, host stamped at ingestion.**

### Rationale

Option 2 is the only option that makes criterion 4 *structurally* achievable
rather than achievable-if-we-remember-to. Host provenance exists for exactly one
instant — when the line comes off a channel we opened to a known host — and
Option 2 captures it there. Every other option either discards it (Option 1, 4) or
buys it by reintroducing the architecture task-03 deliberately removed (Option 3).

The decisive argument is Finding 2 read in reverse. The rotation-ownership problem
looked like a cost to be paid by whichever option won. It is not: it is a cost
*created* by Option 1 and *absent* from Option 2. Choosing not to write remote
lines to the local file means the local file keeps one writer and one rotator, and
its behaviour is unchanged from today. A problem that disappears when you pick the
right structure was never a real requirement — it was a symptom of the wrong one.

The rejected durability benefit of Option 1 deserves an explicit note because it
is the intuitive argument for it: it is not real. The app *is* the tailer, so
"lines survive in the local file if the app dies" describes lines that would never
have been received. The durable store is the remote's own `events.jsonl`, which
the remote forwarder maintains and rotates on its own hooks.

### Key Factors

1. **Host provenance is capturable only at ingestion** — the payload has no host
   field, and merging is lossy and irreversible.
2. **Rotation ownership dissolves** under Option 2 instead of needing a new owner.
3. **`tail -F` and `mv`-rotation are a designed match**, not a lucky one.
4. **DD-002 (observe-only sink) survives untouched** — no listener, no port, no reply.
5. **The ssh child's liveness is the transport's liveness** — criterion 6 gets a
   real trigger for free rather than an invented heartbeat.

### Decided parameters

The task-description asks DD-transport to set two numbers, `N` (silence threshold)
and `X` (how fast a card reflects the trigger). One of them is answered by being
**retired**:

| Parameter | Value | Reason |
|---|---|---|
| Down trigger | ssh child exits, **or** ssh keepalives fail | Two transport-level signals. Line silence is *not* a trigger |
| `N` (silence threshold) | **N/A — deliberately not used** | See below |
| Detection latency | **~45s** worst case (`ServerAliveInterval=15` × `ServerAliveCountMax=3`); **immediate** on child exit | User decision 2026-07-17 |
| `X` (card reflects it) | **≤ 5s after detection** — one board poll cycle | The trigger sets a per-host transport state; the board reads it on its existing poll |
| Down state | distinct `unreachable` — **never** `running`/`waiting` | Criterion 6 negative assertion |
| Replay window | `tail -n 200 -F` | Recovers recent history on reconnect without unbounded replay |
| Dedup | **content-based**, not byte-offset | A remote byte cursor cannot survive remote rotation (no inode analogue over `tail` stdout) |

**Why `N` is retired rather than assigned.** The task-description framed down-detection
as "no line for `N` seconds," and an earlier draft of this table kept line-silence in the
trigger alongside keepalives — which was confused, since keepalives are transport-level
and make the line-silence clause dead weight. Worse, line silence is *the wrong signal in
kind*: a healthy agent thinking for two minutes emits no lines, so any `N` short enough to
be useful will eventually mislabel a working agent as unreachable, and any `N` safe enough
to avoid that is too slow to be useful. TCP keepalive on the ssh channel measures **the
transport**, which is the thing criterion 6 is actually about, and it structurally cannot
confuse "quiet" with "gone." So `N` is not a number this decision picks; it is a parameter
this decision removes.

**`X` and detection latency are separate, and the earlier draft conflated them.** The ~45s
is how long the *transport* takes to notice a silent partition. `X` is how long the *card*
takes to show it once noticed — and on the instant path (ssh child exits) the 45s does not
apply at all, so criterion 6's bound is `X`, not 45s. Both are stated above.

## Consequences

### Positive

- Criterion 4 (host namespacing) becomes structurally satisfiable.
- Criteria 6 and 9 satisfied largely by the transport's own shape.
- Local behaviour is completely unchanged — no new writer, no rotation change.
- No remote install beyond the forwarder + hook config (see DD-002 of this task).

### Negative

- **Downtime gap.** Hook lines emitted while the app is closed are lost beyond the
  `tail -n 200` window. A remote card may sit stale until its next hook event.
  Accepted: the board is a live view, and the remote `events.jsonl` retains the
  history if it is ever needed.
- **A second ingestion path** into the normalizer. Mitigated by both paths
  producing the same line shape, so only the *source* differs.
- **Per-host supervision** (retry/backoff) is real work, sized by the 2-5 host answer.

### Neutral

- Adds `ghostling_host` to the line vocabulary, alongside the existing
  `ghostling_card_id` splice. Same mechanism, same shape.
- Local lines carry no `ghostling_host`; absent means local.

## Implementation Notes

Stamp host the same way the forwarder stamps card id — a suffix splice, not a JSON
re-encode, so the payload stays verbatim:

```
ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -o BatchMode=yes [-p port] [-i id] <target> \
    'tail -n 200 -F ~/.ghostling/events.jsonl'
```

Dedup must be **content-based** and must cover **both** line kinds — state events
*and* `turn_diff` lines, which travel a separate path and would otherwise replay
every diff on reconnect (criterion 7). State events coalesce in the reconciler
(`HookSessionStore` rank / no-flicker write) and are probably idempotent already;
`turn_diff` is **not** and needs an explicit content key.

Do **not** reuse `HookEventTail`'s inode:offset checkpoint for remote hosts. It is
meaningless over `tail` stdout, and pretending otherwise is how criterion 7 fails.

## Related

- **Task:** [task-description.md](../task-description.md) — blocker DD-transport
- **Related Decisions:** DD-002 (identity binding — supplies `ghostling_card_id`
  on the remote), DD-003 (location model — consumes `ghostling_host`)
- **Constrains:** task-03 `DD-002-observe-only-file-sink.md` (must not regress)

## References

- `app/Sources/GhostlingCore/HookEventTail.swift` — the local sink (file tail, not a listener)
- the forwarder's never-block contract comment (`app/Sources/GhostlingApp/HookInstaller.swift`)
- the forwarder's rotation block, `mv -f "$file" "$file.1"` (`app/Sources/GhostlingApp/HookInstaller.swift`)
- `docs/tasks/task-03-native-core/design-decisions/DD-002-observe-only-file-sink.md`
- `research/02-hook-telemetry-transport.md`, `research/05-critical-assessment.md`
