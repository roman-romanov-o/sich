# US-003: Native hook intake via an observe-only file sink

**Status:** Draft
**Priority:** Critical
**Persona:** Operator (watching sessions in other terminals)
**Estimated Complexity:** L
**Last Updated:** 2026-06-26

## User Story

As an **operator with agents running in other terminal windows**,
I want their hook events to reach the board **without a running HTTP server**,
So that **the board reflects every session even when there is no sidecar process listening**.

## Description

Replace the HTTP hook transport with an **observe-only append-only file sink**. The installed
hook (`ghostling-forward.sh`) stops `curl`-POSTing to `127.0.0.1:8787/hooks` and instead **atomically
appends the event JSON as one line** to a known event file (e.g. `~/.ghostling/events.jsonl`).
The app tails that file, normalizes each line through the ported `_HOOK_KIND` map, and reconciles
it into the Swift `SessionRegistry` (porting `detector/reconciler.py` precedence + staleness).
The detector **never replies** — it only observes — which is exactly why a file is sufficient.

## Acceptance Criteria

- [ ] **AC1 — append → board:** Appending a Claude Code `Stop` event line for session `S` moves
  `S` to the done/idle state on the board within one poll interval, with **no server running**.
- [ ] **AC2 — same normalization:** Each event's `hook_event_name` maps to the same `SignalKind`
  the Python `hook_receiver._HOOK_KIND` produces (`Stop`→STOP, `Notification`→PERMISSION_REQUEST,
  `PreToolUse`+test-runner-command→TEST_RUN_START, etc.); reconciliation precedence + sweep-to-`unknown`
  staleness match `StateReconciler`.
- [ ] **AC3 — observe-only:** The sink is read-only to the app and append-only to the hook; there
  is **no reply path** and no way for the sink to launch a process (watcher discipline holds).
- [ ] **AC4 — survives app-down:** Events appended while the app is not running are **not lost** —
  on next launch the app drains from its last processed offset and the sessions appear.

## Edge Cases

1. **Re-launch without reprocessing**
   - Trigger: app restarts; the event file already has 10k old lines.
   - Expected: the app resumes from a persisted byte offset (or equivalent), not from line 0 —
     no double-counting, no replaying terminal states as fresh.

2. **File rotated / truncated**
   - Trigger: the event file is rotated or truncated (offset now past EOF).
   - Expected: the app detects shrink (offset > size) and resets to 0; no crash, no missed tail.

3. **Concurrent appends from several agents**
   - Trigger: two hooks fire at once.
   - Expected: each writes a whole line atomically (`O_APPEND` single `write`); no interleaved/torn
     lines. The forwarder must append, never read-modify-write.

4. **Garbage / partial trailing line**
   - Trigger: a line is half-written when the app reads (writer mid-append).
   - Expected: the app only consumes up to the last newline; a non-JSON line is skipped, not fatal.

## Dependencies

- **Requires:** ported `detector/hook_receiver.py` (`_HOOK_KIND`, test-runner inference),
  `detector/reconciler.py` (precedence + staleness), `detector/registry.py` (already partly in
  Swift `SessionRegistry`).
- **Enables:** US-001 (single binary), US-004 (delete `server/` + `detector/` Python),
  US-005 (multi-tool — same file, more event-name mappings).

## Related Decisions

- DD-002 (observe-only file sink, not an in-app server) — the load-bearing decision here.

## Notes

The forwarder change is tiny: `curl … --data-binary @-` → append stdin as one line to the event
file (`cat >> "$file"` with a single redirect under `O_APPEND`). The Python `IngestService`'s
"stamp arrival time if the hook carries no timestamp" rule must be preserved so staleness measures
silence from arrival, not from epoch-min.
