# Test Specifications — task-03

This task's central risk is **dropping behavior when the Python is deleted**. So the spec is, first
and foremost, a **parity matrix**: every quota/detector behavior the 66 pytest cases pin today is
mapped to a named `swift test` case that must be green **before** Phase 03 deletes anything
(US-004 AC1, enforced by `execution-dod-native`).

## Harness principles (inherited)

- **Never spends quota, never calls `claude -p`.** Quota tests run over a **fixture transcript dir**
  (recorded `~/.claude/projects` JSONL); hook tests feed **recorded event lines**, not a live agent.
- **Injected clock everywhere.** `now` is a parameter (matching the Python `now=`/`clock=` seams) so
  window aging and staleness are deterministic.
- **Parity tests diff against Python output on a shared fixture** where feasible (run the Python once,
  freeze its JSON, assert the Swift reader reproduces it) — the strongest guard against silent drift.

## Test-ID namespaces (task-03, non-colliding with task-01)

| Range | Area |
|-------|------|
| `TC-UNIT-300..319` | quota: JSONL aging + window/weekly math (Swift) |
| `TC-UNIT-320..339` | hooks: tail durability (offset/rotation/partial line) |
| `TC-INT-300..319` | quota source assembly parity (4 sources, never netted, honest degrade) |
| `TC-INT-320..339` | detector parity (normalize + reconcile + staleness) |
| `TC-INT-340..359` | multi-tool normalization (US-005, stretch) |
| `TC-E2E-300..319` | single-binary (no python, no port) |
| `TC-E2E-320..329` | append → board, no server |

## Parity matrix — Python behavior → Swift case

### Quota (replaces `quota/` + `tests/integration/test_quota_pool_aggregation.py`)

| Python behavior (today) | Pytest origin | New Swift case | Story/AC |
|-------------------------|---------------|----------------|----------|
| Sum 4 token classes on `assistant` turns; skip non-usage records | `jsonl_usage` / TC-UNIT-10x | **TC-UNIT-301** | US-002 AC1 |
| Age usage to 5h rolling window; events age out at +5h | window_math / TC-UNIT-101..102 | **TC-UNIT-302** | US-002 AC1 |
| Weekly cap dominates when binding; reset = sooner of window/weekly | window_math / TC-UNIT-103..104 | **TC-UNIT-303** | US-002 AC1 |
| Malformed line / unreadable file skipped, rest survives | `_events_in_file` | **TC-UNIT-304** | US-002 edge 1 |
| Events older than 7d lookback excluded | `read_usage_events` | **TC-UNIT-305** | US-002 edge 2 |
| Four sources out, interactive `inferred:true`, three `unknown` | TC-INT-101/103 | **TC-INT-301** | US-002 AC2/AC3 |
| No pool netted against another | TC-INT-101/102 | **TC-INT-302** | US-002 AC2 |
| Absent `projects_dir` → empty (real-zero), not `unknown`/full | TC-INT-103 | **TC-INT-303** | US-002 AC3 |
| Caps overridable via env | `WINDOW/WEEKLY_CAP_TOKENS` | **TC-UNIT-306** | US-002 AC4 |
| **Full parity:** Swift `read(now:)` == frozen Python `build_quota_response()` on shared fixture | (diff) | **TC-INT-300** | US-002 AC1 |

### Detector (replaces `detector/` + `server/` + `tests/integration/test_agent_state_detection.py`, `test_hook_endpoint.py`)

| Python behavior (today) | Pytest origin | New Swift case | Story/AC |
|-------------------------|---------------|----------------|----------|
| `_HOOK_KIND` map (Stop→STOP, Notification→PERMISSION_REQUEST, …) | hook_receiver / TC-UNIT-001..002 | **TC-INT-321** | US-003 AC2 |
| `PreToolUse` + test-runner command → TEST_RUN_START | hook_receiver | **TC-INT-322** | US-003 AC2 |
| Missing timestamp → arrival-time stamp (staleness from arrival) | ingest | **TC-INT-323** | US-003 AC2 |
| Reconciler precedence over a recorded sequence | reconciler / TC-INT-001..002 | **TC-INT-324** | US-003 AC1/AC2 |
| Ambiguous signal → `unknown` (no false claim) | classifier / TC-INT-003, TC-UNIT-003 | **TC-INT-325** | US-003 AC2 |
| Silent past threshold → swept to `unknown` | reconciler tick / endpoint sweep-on-read | **TC-INT-326** | US-003 AC2 |
| Dropped / raced hooks reconcile correctly | TC-INT-002, 004 | **TC-INT-327** | US-003 AC1 |
| Append `Stop` line → session done/idle, **no server** | (new; replaces HTTP endpoint test) | **TC-INT-320** | US-003 AC1 |
| Tail resumes from offset; no reprocess on relaunch | (new) | **TC-UNIT-321** | US-003 AC4 / edge 1 |
| `offset > size` (rotation/truncation) → reset to 0 | (new) | **TC-UNIT-322** | US-003 edge 2 |
| Partial trailing line not consumed until newline | (new) | **TC-UNIT-323** | US-003 edge 4 |

### Transport cases retired (explicitly, with reason)

| Python behavior | Why retired (not carried) |
|-----------------|---------------------------|
| HTTP 404 on unknown route (`endpoint._send_error`) | The HTTP server is deleted (DD-002); no route concept under a file sink. |
| `/sessions/{id}` 404 for untracked id | Registry read is in-process now; "untracked" is just `nil`, covered by TC-INT-324. |
| 1 MiB body cap / invalid-JSON-body 400 | No request body; a malformed file line is skipped (TC-INT-321 / TC-UNIT-323). |
| Port autobind (`port=0`) for tests | No port. |

These are **transport** details of a server we are removing — not domain behavior. All **behavioral**
pytest cases are carried above; only these four are dropped, each with a stated reason (US-004 edge 1).

## End-to-end (cutover)

| Case | Asserts | Story/AC |
|------|---------|----------|
| **TC-E2E-301** | Launch app → **0** `python*` child processes; quota panel populated | US-001 AC1/AC3 |
| **TC-E2E-302** | After launch nothing bound on `127.0.0.1:8787`; board shows sessions | US-001 AC2/AC3 |
| **TC-E2E-303** | `grep -r mission_control` / `8787` in `app/` + scripts → clean | US-004 AC2/AC3 |
| **TC-E2E-320** | With no server, append a `Stop` line → board reflects it within one poll | US-003 AC1 |

## Multi-tool (stretch — US-005)

| Case | Asserts |
|------|---------|
| **TC-INT-340** | Cursor `stop` line lights board identically to Claude `Stop` |
| **TC-INT-341** | Session carries `provider`; unknown event → `UNKNOWN` |

## Coverage summary

| Type | Cases | Stories |
|------|-------|---------|
| Unit | TC-UNIT-301..306, 321..323 (9) | US-002, US-003 |
| Integration | TC-INT-300..303, 320..327 (12) | US-002, US-003 |
| Integration (stretch) | TC-INT-340..341 (2) | US-005 |
| E2E | TC-E2E-301..303, 320 (4) | US-001, US-003, US-004 |

**DoD gate:** the matrix above (excluding the stretch row) must be 100% bound to green `swift test`
cases before Phase 03 deletes `src/mission_control`. `execution-dod-native` checks the dual baseline
(pytest count while it still exists, then swift count after) so no case is silently lost in the swap.
