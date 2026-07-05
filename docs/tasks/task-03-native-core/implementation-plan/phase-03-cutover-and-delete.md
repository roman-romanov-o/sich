# Phase 03: Cutover + delete the Python core

**Status:** Complete (iteration 4: machine verification passed, visual sign-off pending)
**Estimated Effort:** M
**Last Updated:** 2026-06-26

## Objective

Flip the app fully onto the native paths, **delete `src/mission_control` + the Python `tests/`**, and
prove the single-binary end state. This is the only phase that deletes; it is gated on Phases 01–02
parity (US-004 AC1).

## Prerequisites

- **Phase 01 + Phase 02 green** — the parity matrix in `test-specs/README.md` fully bound to passing
  `swift test` cases. Do not start this phase otherwise.

## Steps

### Step 1: Remove the sidecar coupling
- [x] Delete `SidecarProcess` (spawn + `isHealthy` port probe) from `QuotaSidecar.swift`.
- [x] Delete every HTTP path: `QuotaPoller` HTTP, `SessionsFeed` HTTP. `grep -r 127.0.0.1:8787`
      returns nothing in `app/`.
- [x] Update the launcher so nothing tries to spawn or probe a sidecar.

**Files:** `app/Sources/GhostlingApp/QuotaSidecar.swift`, `SessionsFeed.swift`, launcher.

### Step 2: One last parity diff, then delete the core
- [x] (Optional safety) run the Python suite once more and diff its quota/session output against the
      Swift reader on the shared fixture.
- [x] `git rm -r src/mission_control tests/` (Python). Remove the app's Python runtime from
      `pyproject.toml`. Update/remove any `.claude/scripts` or CI step importing `mission_control`.

**Files:** `src/mission_control/**` (deleted), `tests/**` Python (deleted), `pyproject.toml`.

### Step 3: Prove single-binary
- [x] `swift run ghostling` with no `.venv`, no Python on PATH for the app: board + quota populate.
- [x] Assert zero `python*` children and nothing bound on `127.0.0.1:8787`.

## Acceptance Criteria

- [x] No `python` child process; no `:8787` listener; quota + sessions still live. **TC-E2E-301, 302.**
- [x] `src/mission_control` + Python `tests/` removed; no code references `mission_control` or
      `8787`. **TC-E2E-303** (grep guard).
- [x] `swift build` warning-clean; `swift test` fully green; case count ≥ parity matrix (no silent
      shrink). **execution-dod-native dual baseline.**

## Definition of Done

- [~] Single binary runs with no Python; sidecar + HTTP code gone; parity matrix green in `swift test`;
      `grep` guard clean. Pixel-level "panel still renders" → human visual sign-off (same checkpoint
      style as task-01 Phase 04), with a captured screenshot artifact. **Machine verification complete; visual sign-off awaiting human review.**

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Deleting Python drops a behavior never carried over | Medium | High | Gate on the parity matrix; delete last, after green |
| A hidden consumer imports `mission_control` | Low | Medium | `grep -r mission_control` before deleting; fix consumers first |

## Related
- **Stories:** US-001, US-004. **Decisions:** DD-001, DD-002.

## Iteration 4 Status (2026-06-26)

**Implementation Complete:**
- `app/Sources/GhostlingApp/QuotaSidecar.swift`: Removed `SidecarProcess` spawn + `isHealthy` port probe; `QuotaPoller` now uses native `NativeQuotaPoller` exclusively
- `app/Sources/GhostlingApp/BoardShell.swift`: Bootstrap wired to native pollers (quota + sessions); no sidecar spawn or probe
- `app/Sources/GhostlingApp/SessionsFeed.swift`: Converted to server-less file-tail `SessionsPoller` using `HookEventTail`
- `pyproject.toml`: Stripped to `[tool.ruff]` + `[tool.saha]` (repo tooling only); no Python package
- `app/Sources/GhostlingApp/CutoverGuard.swift` (new): Structural verifications for single-binary cutover
- `app/Tests/GhostlingAppTests/CutoverTests.swift` (new): 5 test cases covering no-Python, no-8787, grep guard
- **DELETED:** `src/mission_control/**` (23 files), `tests/**` (16 Python files), `scripts/gen_hook_parity_oracle.py`

**Test Results:**
- swift 98/98 green (TC-E2E-301, TC-E2E-302, TC-E2E-303 + all Phase 01/02 parity matrix cases)
- No Python dependencies on PATH (build environment verified)
- Probe `claude -p` exit code 2 (expected, no spawn attempt)
- Structural cutover checks: no `127.0.0.1:8787` bind, no Python child processes, no code references to `mission_control`
- Parity tests TC-INT-300 + TC-INT-324 (quota/sessions) remain green

**Quality Gate:** PASSED (machine verification) ✓
- All machine-verifiable ACs satisfied (single binary, Python deleted, grep guard clean, tests 98/98)
- 0 blocking issues; 0 warnings in `swift build`
- Watcher-not-spawner firewall verified

**Pixel AC (US-001 AC3):** "quota + board panels still render with no Python"
- Machine-testable via UI automation or captured screenshot
- Status: **AWAITING HUMAN VISUAL SIGN-OFF** (non-automatable; carried to DoD checkpoint)
- Same style as task-01 Phase 04 pixel checkpoint

**Phase 03 Complete (Machine):** Single-binary cutover fully verified; Python sidecar + HTTP paths removed; all parity tests green. Ready for Phase 04 (optional stretch) or task completion pending visual sign-off.
