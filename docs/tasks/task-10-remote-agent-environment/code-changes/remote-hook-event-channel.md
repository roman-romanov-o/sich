# Code Change: Remote Hook Event Channel

**Type:** Event (line-oriented JSONL over an ssh `tail -F` relay)
**Transport:** `ssh <target> 'tail -n 200 -F ~/.ghostling/events.jsonl'` → stdout → in-memory
**Authentication:** ssh (the operator's existing key/agent). No new auth surface.
**Status:** Draft

## Overview

The remote host already writes hook lines to `~/.ghostling/events.jsonl` exactly as the
laptop does — the forwarder script is the same one (`HookInstaller.swift`'s embedded `forwarderScript`).
This contract defines what the **relay** hands to the normalizers, which is the only
new boundary: an ingestion step that stamps host provenance and suppresses replayed
lines, sitting between ssh's stdout and the existing `HookNormalizer` /
`TurnDiffNormalizer`.

**Producers:** the remote forwarder script (unchanged, not redistributed — US-005 installs
the same script remotely).
**Consumers:** `HookNormalizer.normalize` → `HookSessionStore.ingest` (card state);
`TurnDiffNormalizer.normalize` → drill-in diffs.

Two line kinds share the file and must be contracted separately, because **they do not
have the same identity fields**. This is the finding that settles task OQ2 / US-008.

---

## Line Kind A: State Hook

Claude Code's own hook payload, appended raw (the forwarder's raw-append (`printf '%s\n' "$line" >> "$file"`)), with
`ghostling_card_id` spliced on when the pane carries it.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `hook_event_name` | string | Yes | Mapped via `HookNormalizer.hookKind` (`HookNormalizer.swift:19-31`). Unknown → `.unknown`, never fatal. |
| `session_id` | string | Yes | Claude's session id. `nil` → `""` (`HookNormalizer.swift:47`). |
| `cwd` | string | No | Remote absolute path. **Not host-qualified** — see AC-2 below. |
| `timestamp` | number \| string | **No** | Epoch seconds or ISO 8601. **Absent → stamped with local arrival time** (`SignalEvent.swift:79`). |
| `ghostling_card_id` | string | No | Spliced by the forwarder only when `$GHOSTLING_CARD_ID` is set (US-004). |
| `tool_name`, `tool_input.command` | string | No | Only read to promote `PreToolUse` → `testRunStart`. |
| `ghostling_host` | string | **Added by us** | See ingestion contract. |

**There is no `seq`, no `occurred_at`, and no per-emission unique id.** The forwarder
states this deliberately (the forwarder's header comment in `HookInstaller.swift`): "a per-hook appender can't
produce a global monotonic counter; ordering uses the event's own `timestamp`."

### Dedup key (state hooks)

**Key: the SHA-256 of the raw line bytes, qualified by host** — `(ghostling_host, sha256(line))`.

Keying on the **normalized `SignalEvent` is incorrect and will silently fail.**
`SignalTimestamp.parse` falls back to *arrival* time when `timestamp` is absent
(`SignalEvent.swift:72-80`), so one byte-identical line replayed on reconnect
normalizes to a **different** `Date` and therefore a non-equal `SignalEvent`. Dedup must
happen on the raw bytes, **before** normalization. This is the specific trap US-008 AC-3
names when it says a byte cursor cannot satisfy content-based dedup — the same reasoning
rules out an equality check on the normalized value.

The line already carries the `ghostling_card_id` splice at hash time, which is stable per
card, so hashing the whole line is safe.

### The harm is regression, not duplication

Re-ingesting an identical state event is **largely idempotent already**:
`HookSessionStore` folds events into state and records a transition only on real change
(`HookSessionStore.swift:167-172` — `write` compares against `currentState` and appends a
transition only `if changed`). The real damage from `-n 200`'s replay is a **stale line
moving a card backwards**.

The regression is narrower than it first looks, and naming it precisely matters because
the obvious example is **false**. Replaying an old `UserPromptSubmit` after the session
reached `done` does **not** re-open it: `classify` returns `prior` for `.userInput` unless
prior is `.waitingForInput`/`.idle`, and every absolute signal passes through
`settled(prior:next:)` = `prior.detectorFallback ?? next`, where `done` is deliberately
sticky (`BoardCard.swift:28-33`). A test written from that example cannot be made red.

The two replays that **do** regress a card:

1. **A replayed `SessionStart`/`PostToolUse` against a `.waitingForInput` prior.** Both map
   absolute → `.running`, and `waitingForInput.detectorFallback` is `nil`, so
   `settled(.waitingForInput, .running)` = `.running`. A stale line **silently
   extinguishes the attention signal** — the one thing the product exists to raise. This
   is the primary example US-008 AC-1 must be written from.
2. **A stale `Stop` against a `.running` prior** → `.idle`, de-running a live card.

`ingest` has no timestamp-vs-current-state guard, so a stale batch does apply. US-008 AC-1
should be read as "a reconnect does not move a card backwards", which is stronger than
counting events and is what the test must assert.

### Errors

| Case | Behavior |
|------|----------|
| Non-JSON line | `nil`, skipped, not fatal (`HookNormalizer.swift:10, 43`). Unchanged. |
| Unknown `hook_event_name` | `.unknown` (`HookNormalizer.swift:68`). Unchanged. |
| Missing `session_id` | `""` — folds into a degenerate session. Pre-existing; not this task's to fix. |
| Missing `timestamp` | Arrival-stamped. **Interacts with dedup — see above.** |

---

## Line Kind B: Turn Diff

Emitted by the forwarder's own `printf` (the forwarder's `turn_diff` printf), not by Claude.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `ghostling_event_type` | string | Yes | Literal `"turn_diff"`; a line without it is not a diff (`DiffModel.swift:143`). |
| `session_id` | string | Yes | ⚠️ **Sanitized**, unlike Line Kind A's. The forwarder emits `$safe_session` = `session_id \| tr -cd '[:alnum:]_.-'` (the forwarder's `safe_session` assignment, emitted at `:213`), while state hooks carry Claude's **raw** `session_id`. Any join across the two kinds crosses a sanitization boundary — join on the sanitized form, or not at all. |
| `iteration` | number | Yes | Persisted at `$state_dir/iteration` (the forwarder's `UserPromptSubmit` branch). **Increments per `UserPromptSubmit`, NOT per diff** — so it is monotonic but *not unique per diff*. See the dedup key below. Defaults to `0` on read failure. |
| `timestamp` | number | Yes | `date +%s` — **second granularity** (the forwarder's `turn_diff` printf). |
| `cwd_base64` | string | Yes | base64 of the remote cwd. |
| `diff_base64` | string | Yes | base64 unified diff. Undecodable → whole line `nil`. |
| `session_diff_base64` | string | No | |
| `ghostling_card_id` | string | No | Appended via `card_field`. |
| `ghostling_host` | string | **Added by us** | See ingestion contract. |

### Dedup key (turn diffs)

**Key: `(ghostling_host, session_id, iteration, sha256(diff_base64))`.**

The forwarder is **not** fully stateless — it keeps a per-session iteration counter on
disk — and that is the correction to US-008's premise. But `iteration` alone is **not a
unique diff identity**, and assuming it was is an error this contract previously made.
Read the forwarder's two branches:

- `iteration` increments **only** on `UserPromptSubmit` (the forwarder's `UserPromptSubmit` branch).
- `turn_diff` is emitted on **`Stop`**, which **reads** the counter without  incrementing it (the `Stop` branch).
- The `Stop` branch clears `$diff_path` but **never clears `$state_dir/checkpoint`**, so
  it stays armed.

So two `Stop`s without an intervening `UserPromptSubmit` emit two `turn_diff` lines with
the **same `iteration`** and possibly **different diffs**. Keyed on the triple alone, the
second is silently eaten — a lost diff, which is exactly the failure US-008 exists to
prevent, arriving through the fix rather than the bug. The `sha256(diff_base64)` tiebreak
costs one hash per diff and removes the guess.

**Why not just `sha256(raw line)`, as for state hooks?** It would work, and it is simpler —
so the asymmetry needs a reason, or it will be simplified away. The raw-bytes key includes
`timestamp` (`date +%s`), so two `Stop`s emitting the **same diff** in different seconds
hash differently and both are admitted: the operator sees the same diff twice in drill-in,
which is the duplication US-008 exists to prevent. The composite key deliberately ignores
`timestamp` and `cwd_base64` and keys on **content identity**, so a same-content diff is
recognised as the duplicate it is regardless of when it was emitted. State hooks can afford
raw bytes because their duplicates fold idempotently into state; diffs accumulate into a
list, so theirs must be recognised.

This also revises US-008 edge case 1: "two genuinely identical events must not be eaten"
**does** reach diffs — but only for diffs that are byte-identical in content as well as
iteration, where eating one is correct. The asymmetry holds for both kinds: **prefer
eating a true duplicate over admitting a stale replay.**

For state hooks it arises more simply, and timestamp granularity is **not** the mechanism:
the forwarder appends Claude's line **verbatim** (the forwarder's raw-append path) and adds no
`date +%s` of its own, and Line Kind A's `timestamp` is not required at all. So two
successive identical `PostToolUse` lines are byte-identical outright, and a raw-bytes key
eats the second. That is harmless — the fold is idempotent — but it is worth being exact
about *why*, because "the timestamps differ" is the property the diff key depends on and
borrowing it here would make both arguments look like one rule when they are two.

### Errors

| Case | Behavior |
|------|----------|
| `ghostling_event_type` ≠ `turn_diff` | `nil` — this is how the two kinds are told apart. |
| `diff_base64` undecodable | `nil`, whole line dropped (`DiffModel.swift:144-147`). |
| base64 line-wrapped by GNU coreutils | Survives via `tr -d '\n'` (the forwarder's `base64 | tr -d '\n'`) — **by luck, not by design**. US-002 audits this. |
| Missing `iteration` | `0` (`DiffModel.swift:152`). Only reachable if `$state_dir` is unwritable. Two such diffs no longer collide blindly — the `sha256(diff_base64)` tiebreak separates them unless their content is also identical. |

---

## Ingestion Contract

The relay is a **normalizer input**, not a file writer.

```
RelayLine = (host: String, raw: Data)
```

1. **`ghostling_host` is spliced at ingestion**, before either normalizer sees the line.
   The payload has no hostname field (zero grep hits), so provenance exists for exactly
   one instant — the channel was opened to a known host — and is unrecoverable after.
   Splice mechanically, mirroring the forwarder's own `ghostling_card_id` splice
   (the forwarder's card-id injection): the line ends `}`, so rewrite to
   `…,"ghostling_host":"<host>"}`.
2. **Dedup by kind**, per the two keys above: `(host, sha256(raw line))` for state hooks,
   and `(host, session_id, iteration, sha256(diff_base64))` for diffs. The diff key is
   **four** parts, not three — `iteration` alone does not identify a diff (see Line Kind B).
3. **Never append to the local `~/.ghostling/events.jsonl`** (US-003 AC-3). Merging
   destroys provenance irreversibly: a remote **macOS** host with `/Users/roman/proj`
   and a local card at the same path emit byte-identical `cwd`, and the directory join
   in `BoardShell.applySessions` (its `liveState(forDir:id:joinByDir:in:)` call) would
   move the **local** card.
4. **No inbound listener, no port, no reply** — preserves task-03 DD-002's observe-only
   sink. The only `NWListener` in the app remains `StaticFileServer.swift:14`.

`host` is the relay's own `RemoteTmuxSpec.host` (post-trim, post-validation — see
[remote-tmux-command.md](remote-tmux-command.md)), never free text from a payload.

### Dedup memory bound

**Both dedup sets are bounded per host at 500 entries, evicted oldest-first (FIFO).**
Unbounded, `(host, sha256(line))` grows for the lifetime of the app — every line ever
relayed, retained forever, to guard against a replay window that is **200 lines** wide
(`tail -n 200`).

500 is the replay window with slack, not a tuned number: the set only has to outlive one
reconnect's `-n 200`, and eviction is safe precisely because an evicted entry can only be
re-admitted if it reappears — which, past a 500-line horizon, it cannot, since `-n 200`
never reaches back that far. If the relay's `-n` value changes, this bound moves with it;
they are one decision, and the constant should name the relationship rather than repeat
the number.

The bound is per host so that one chatty host cannot evict another's history and resurrect
its replays. US-008 AC-3's test asserts eviction, which is why the bound has to be a
contract rather than an implementation detail.

## Guarantees

- **Ordering:** per-session by the event's own `timestamp`; ties broken by source rank
  (`sourceRank` = `[.hook: 3, .jsonl: 2, .pty: 1]`, `HookSessionStore.swift:39`, applied in
  the sort at `:125-126`). Unchanged by this task.
- **Delivery:** at-least-once. `-n 200` replays on every reconnect; dedup absorbs it.
- **Retention:** remote-side rotation to `events.jsonl.1` at 5 MiB
  (the forwarder's header comment). `tail -F` (`--follow=name --retry`) is a designed
  match for `mv`-based rotation.

## Related

- **Stories:** US-003, US-008, US-002, US-004
- **Decisions:** DD-001
