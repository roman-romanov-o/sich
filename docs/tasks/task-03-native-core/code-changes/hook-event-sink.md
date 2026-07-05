# Code Change: Hook event sink (observe-only file transport)

**Status:** Draft
**Last Updated:** 2026-06-26

## Overview

Replaces the `127.0.0.1:8787/hooks` POST receiver with an **append-only file** the installed hook
writes and the app tails. Three small `GhostlingCore` pieces plus a one-line forwarder change. No
listener, no port, no reply (DD-002).

## The event file

- **Path:** `~/.ghostling/events.jsonl` (override via `GHOSTLING_EVENTS_FILE`).
- **Format:** one Claude-Code-hook-shaped JSON object per line, exactly what the hook receives on
  stdin, plus an optional `provider` field (defaults `"anthropic"`; set by non-Claude installers,
  US-005). Append-only, newline-terminated, never rewritten in place.

## Forwarder change — `.claude/scripts/ghostling-forward.sh`

**Before:** `curl -sS --max-time 1 -X POST http://127.0.0.1:8787/hooks --data-binary @-`
**After:** atomically append stdin as one line to the event file:
```sh
# Append-only, single write under O_APPEND → atomic per line; never blocks the watched session.
file="${GHOSTLING_EVENTS_FILE:-$HOME/.ghostling/events.jsonl}"
mkdir -p "$(dirname "$file")"
cat >> "$file"; printf '\n' >> "$file"   # stdin is one JSON object; ensure newline-terminated
exit 0
```
Same watcher discipline: never blocks, output discarded, always `exit 0`.

## Swift pieces

### `HookEventTail` — durable tail

```
init(file: URL, offsetStore: URL)        // persists last byte offset next to the file
poll() -> [Data]                          // returns new whole lines since last offset; advances it
```
- Resumes from persisted offset (no reprocessing on relaunch — US-003 AC4 / edge 1).
- `offset > fileSize` (rotation/truncation) → reset to 0 (edge 2).
- Reads only up to the **last newline**; a partial trailing line waits for completion (edge 4).

### `HookNormalizer` — port of `detector/hook_receiver.py`

```
normalize(_ line: Data) -> SignalEvent?   // nil on non-JSON (skipped, not fatal)
```
- `_HOOK_KIND` map ported verbatim: `Stop→STOP`, `Notification→PERMISSION_REQUEST`,
  `SessionStart→SESSION_START`, `UserPromptSubmit→USER_INPUT`, `Pre/PostToolUse→TOOL_USE`,
  `PostToolUseFailure/PermissionDenied/StopFailure→ERROR_EXIT`, `PermissionRequest→PERMISSION_REQUEST`.
- `PreToolUse` whose `tool_input.command` contains a known test runner (`pytest`, `jest`, `vitest`,
  `cargo test`, `go test`, `npm test`) → `TEST_RUN_START`.
- Missing `timestamp` → stamp arrival time (so staleness measures silence from arrival, not epoch).
- Unknown event name → `UNKNOWN` (session shown, no false done/waiting claim).

### Reconcile into `SessionRegistry` — port of `detector/reconciler.py`

```
ingest(events) -> Void          // applies precedence + writes session status
sweepStale(now:) -> Void        // decay sessions silent past the threshold → unknown
```
Precedence + sweep-to-`unknown` semantics must match `StateReconciler`. The app calls `poll()` →
`normalize` → `ingest`, then `sweepStale(now:)` on the same cadence the board polls (sweep-on-poll,
mirroring the Python sweep-on-read; no background timer needed).

## Wiring (app side)

`SessionsFeed.swift`'s HTTP poll of `/sessions` is replaced by the tail → normalize → ingest loop
over the local registry. The reconciled registry is what the board already renders.

## Related
- **User Stories:** US-003 (this), US-005 (the `provider` field + per-agent installers), US-004.
- **Decisions:** DD-002.
- **Tests:** TC-INT-321..324, TC-UNIT-321, TC-E2E-320.
