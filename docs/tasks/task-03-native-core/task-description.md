# Task Description: Native Core — Eliminate the Python Sidecar

**Status:** Approved
**Last Updated:** 2026-06-26

## Overview

Make the Swift app self-sufficient: read quota usage and receive agent hooks **in-process**,
delete the Python sidecar (`src/mission_control`) and its `127.0.0.1:8787` HTTP server, and
ship a **single binary** — the same single-app model cmux uses. The product behavior on
screen does not change; what changes is that there is no second language, no second process,
no localhost port, and no two-sided wire to keep in sync.

## Goals

- **G1.** The interactive-pool quota gauge is populated by Swift reading
  `~/.claude/projects/**/*.jsonl` directly (token-usage sum aged to a 5h rolling window +
  weekly cap), with the same `inferred`/availability/confidence semantics as today.
- **G2.** Agent hook events reach the board with **no running HTTP server** — the installed
  hook appends a JSON line to an event file; the app tails it, normalizes, and reconciles.
- **G3.** Every behavior currently pinned by the 66 pytest cases for the quota + detector
  logic is re-pinned by `swift test` **before** any Python is deleted.
- **G4.** `src/mission_control` and the Python `tests/` suite are deleted; launching the app
  spawns **zero** child Python processes and binds **no** TCP port.
- **G5. (stretch)** Non-Claude agents (Cursor, Codex, Gemini) light up the same board signals
  via per-agent hook installers that write to the same event file.

## Non-Goals

- **Not** changing the two-pool quota model or the projection math — it is already correct
  and already duplicated natively in Swift (`QuotaProjection`). This task only moves *where
  the source readings originate*.
- **Not** adding new precise quota sources. Agent-SDK credit / Codex / Gemini remain
  `UNKNOWN` exactly as today (honest-degradation rule).
- **Not** adding an in-app HTTP or socket server (DD-002 explicitly rejects re-introducing a
  listener — that is the very thing we are removing).
- **Not** touching the terminal substrate, board layout, or quota panel UI.

## Technical Context

**What the sidecar actually does (the whole job to replace):**

1. **Quota source reads** — `quota/jsonl_usage.py::read_usage_events()` globs
   `~/.claude/projects/**/*.jsonl`, sums `input/output/cache_*` tokens on each `assistant`
   turn into `UsageEvent`s; `quota/live.py::build_quota_response()` ages them to a 5h window
   + weekly cap (caps are env-overridable calibration knobs) and assembles **one estimated
   interactive source + three UNKNOWN sources** (Agent-SDK credit, Codex, Gemini). It emits
   raw `SourceReading`s — because **the projection is intentionally duplicated in Swift**
   (`QuotaProjection` re-projects identically). So only the **JSONL walk + window aging** is
   missing from Swift; the projection is not.

2. **Hook intake** — `server/endpoint.py` (a `ThreadingHTTPServer` on `127.0.0.1:8787`)
   receives Claude Code hook POSTs at `/hooks`, hands each to `server/ingest.py::IngestService`,
   which routes through `detector/hook_receiver.py::normalize_hook` (the `_HOOK_KIND` map)
   → `detector/reconciler.py::StateReconciler` → `detector/registry.py::SessionRegistry`,
   with a **sweep-on-read** staleness decay. It serves `/sessions` (+ `/sessions/{id}`).

3. **HTTP transport** — the Swift app's `QuotaSidecar.swift` spawns the sidecar
   (`SidecarProcess`) and polls `/quota` (`QuotaPoller`) and `/sessions` (`SessionsFeed`).

**Why the detector can drop the server entirely:** the detector is **observe-only** — it
never replies to a hook (`ghostling-forward.sh` already discards the response and always
`exit 0`). A request/response server is therefore unnecessary; an append-only file the hook
writes and the app tails carries the same information, survives the app being down (events
queue in the file and drain on launch), and removes the port collision class we already hit
(`EADDRINUSE`, see `SidecarProcess.isHealthy`).

**Reuse / prior art:** the cmux evaluation ([[cmux-detection-is-hooks-not-terminal-scraping]])
confirmed multi-tool detection is just per-agent hook installers funneling into one sink —
exactly this design. The Rosetta-Stone table (which config file / which event = "done" vs
"needs-you" for ~15 agents) is the input to the Phase-04 stretch.

## Constraints

- **Watcher-not-spawner** (hard, economic): the core observes; it never spawns `claude -p`.
  The sink is append-only; the app only ever *reads* it.
- **Parity-before-deletion** (integrity): no `src/mission_control` file is deleted until the
  behavior it owned is green in `swift test`. Phase 03 is gated on Phases 01–02 parity.
- **No new dependency:** Swift Foundation covers file globbing, ISO-8601, JSON, and a poll
  timer. No package added (ponytail rung 4).
- **Single binary:** post-cutover, `swift run ghostling` needs no Python, no `.venv`, no port.

## Success Criteria

- [ ] **SC1 (G1):** interactive gauge value, `inferred=true`, and reset time match the
      Python output for the same JSONL fixture (TC-INT-301; TC-UNIT-301..303).
- [ ] **SC2 (G2):** appending a Claude `Stop` hook line to the event file moves that session
      to the done/idle state on the board within one poll, with no server running (TC-INT-321;
      TC-E2E-320).
- [ ] **SC3 (G3):** the quota + detector behaviors from the 66 pytest cases are bound to named
      `swift test` cases (parity matrix in `test-specs/README.md`), all green.
- [ ] **SC4 (G4):** launching the app spawns 0 Python processes and binds 0 TCP port; quota +
      sessions still populate (TC-E2E-301, TC-E2E-302). `src/mission_control` + `tests/` removed.
- [ ] **SC5 (G5, stretch):** a Cursor `stop` event in the file lights the board identically to
      a Claude `Stop` (TC-INT-340).

## Related

- **Decisions:** DD-001 (eliminate the sidecar / port to Swift), DD-002 (observe-only file
  sink, not a server). Inherits task-01 DD-001 (libghostty / pool firewall).
- **Memory:** [[real-prototype-assembled-data-paths-live]], [[cmux-detection-is-hooks-not-terminal-scraping]],
  [[watcher-not-spawner-quota-constraint]], [[python-sidecar-built-iter1-3]].
- **Supersedes:** the sidecar transport described in `app/Sources/GhostlingApp/QuotaSidecar.swift`
  (kept as fallback through Phase 02, removed in Phase 03).
