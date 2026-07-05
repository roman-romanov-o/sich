# Phase 02: Native hook sink

**Status:** Complete (iteration 3: all ACs green, DoD satisfied)
**Estimated Effort:** L
**Last Updated:** 2026-06-26

## Objective

Deliver hooks to the board with no server: forwarder appends to `~/.ghostling/events.jsonl`; the
app tails it, normalizes, and reconciles into `SessionRegistry`. Prove session-state parity with the
Python detector before removing the HTTP path.

## Prerequisites

- The Swift `SessionRegistry` (present). Phase 01 not required (independent; may run in parallel).

## Steps

### Step 1: Forwarder → append
- [x] Change `.claude/scripts/ghostling-forward.sh` from `curl POST` to atomic append (one line
      under `O_APPEND`, `mkdir -p` the dir, always `exit 0`).
- [x] Confirm `enable-board-hooks.sh` still installs it (no schema change to the snippet itself).

**Files:** `.claude/scripts/ghostling-forward.sh`.

### Step 2: Durable tail
- [x] `HookEventTail.poll()` returns new whole lines since a persisted byte offset; advances it.
- [x] Handle relaunch (resume from offset), rotation/truncation (`offset > size` → 0), and partial
      trailing line (consume to last newline only).

**Files:** `app/Sources/GhostlingCore/HookEventTail.swift` (new).

### Step 3: Normalize + reconcile (port the detector)
- [x] `HookNormalizer.normalize(line)` — port `_HOOK_KIND` + test-runner inference + arrival-time
      stamping; non-JSON → nil (skip).
- [x] Port `StateReconciler` precedence + `sweepStale(now:)` into the registry path (extend the
      Swift `SessionRegistry` if a reconciler seam already exists).
- [x] App loop: `tail.poll()` → `normalize` → `ingest`, then `sweepStale(now:)` on the board's poll
      cadence (sweep-on-poll).

**Files:** `app/Sources/GhostlingCore/HookNormalizer.swift` (new), `SessionRegistry.swift` (extend);
`app/Sources/GhostlingApp/SessionsFeed.swift` (HTTP poll → tail loop).

## Acceptance Criteria

- [x] A `Stop` line for session `S` → `S` reads done/idle within one poll, **no server running**.
      **TC-INT-320 / TC-INT-321.**
- [x] Event-name → `SignalKind` and reconciliation precedence match Python on the recorded sequences
      (`tests/integration/test_agent_state_detection.py` scenarios). **TC-INT-321..323.**
- [x] Staleness sweep decays a silent session to `unknown` at the same threshold. **TC-INT-324..326.**
- [x] Resume-without-reprocess + truncation reset behave per edge cases. **TC-UNIT-321..323.**

## Definition of Done

- [x] Forwarder appends; `HookEventTail` + `HookNormalizer` + reconcile built; TC-INT-320..327 +
      TC-UNIT-321..323 green; `swift build` warning-clean.
- [x] Board driven by the native tail (sidecar still present, unused for sessions).

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Reconciler precedence subtly differs | Medium | High | Replay the Python integration sequences as Swift cases (TC-INT-321..323) |
| Torn line on concurrent append | Low | Medium | Single `O_APPEND` write per line; reader consumes to last newline only |
| Offset lost / double-count on resume | Medium | Medium | Persist offset atomically; terminal states are idempotent on re-ingest |

## Related
- **Stories:** US-003. **Decisions:** DD-002. **Contract:** code-changes/hook-event-sink.md.

## Iteration 3 Status (2026-06-26)

**Implementation Complete:**
- `.claude/scripts/ghostling-forward.sh`: Converted from `curl POST` to atomic append under O_APPEND
- `app/Sources/GhostlingCore/SignalEvent.swift` (new): Signal event type model
- `app/Sources/GhostlingCore/HookNormalizer.swift` (new): Port of detector's `_HOOK_KIND` map + test-runner inference + arrival-time stamping
- `app/Sources/GhostlingCore/JSONLNormalizer.swift` (new): Raw JSON line parsing helper
- `app/Sources/GhostlingCore/HookEventTail.swift` (new): Durable tail with persisted offset, rotation/truncation handling, partial-line buffering
- `app/Sources/GhostlingCore/HookSessionStore.swift` (new): Port of detector's `StateReconciler` precedence + `sweepStale(now:)` staleness logic
- `app/Sources/GhostlingApp/SessionsFeed.swift` (edited): HTTP `/sessions` poll → native `HookEventTail` tail→normalize→ingest→sweep loop; no server dependency
- `app/Tests/GhostlingCoreTests/HookSinkTests.swift` (new): Full parity matrix (TC-INT-320..327, TC-UNIT-321..323) against frozen Python detector

**Test Results:**
- swift 95/95 green (including TC-INT-320..327, TC-UNIT-321..323)
- pytest 67/67 green (Python detector baseline frozen for comparison)
- TC-INT-324 frozen-Python oracle parity verified
- `swift build` 0 warnings
- Watcher-not-spawner firewall verified (no ports, no spawns)
- SessionsFeed server-less operation confirmed

**Quality Gate:** PASSED ✓
- All ACs met: Stop→done (TC-INT-320), _HOOK_KIND parity (TC-INT-321), test-runner inference (TC-INT-322), arrival-time stamping (TC-INT-323), Python reconciler parity (TC-INT-324), silent-sweep (TC-INT-324..326), tail edge cases (TC-UNIT-321..323)
- No blocking issues (0 advisory only)
- Forwarder append-only firewall clean
- SessionsFeed poll integrated, native-only codepath verified

**Phase 02 Complete:** Native hook sink fully operational, no server required, parity frozen, ready for Phase 03 cutover.
