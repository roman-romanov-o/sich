# US-004: Retire the Python core (parity-gated deletion)

**Status:** Draft
**Priority:** Critical
**Persona:** Maintainer
**Estimated Complexity:** M
**Last Updated:** 2026-06-26

## User Story

As the **maintainer of this codebase**,
I want `src/mission_control` and its Python test suite **deleted once Swift proves parity**,
So that **there is one language, one build, one binary — and no two-sided wire to keep in sync**.

## Description

The 66 pytest cases are currently the **source of truth** for the quota + detector behavior.
Deleting the Python without carrying that truth forward would silently drop coverage. So this
story is explicitly **parity-gated**: every quota/detector behavior pinned by pytest is first
re-pinned by a named `swift test` case (the parity matrix in `test-specs/README.md`), the app is
flipped to the native paths (US-002/US-003), and **only then** is `src/mission_control` + the
Python `tests/` removed and the Python-app coupling (`SidecarProcess`, `QuotaPoller` HTTP,
`SessionsFeed` HTTP) deleted.

## Acceptance Criteria

- [ ] **AC1 — parity proven first:** Every row of the `test-specs` parity matrix maps a pytest
  behavior to a green `swift test` case **before** any deletion (the DoD gate, enforced by
  `execution-dod-native`).
- [ ] **AC2 — core deleted:** `src/mission_control/{quota,detector,server,board}` and the Python
  `tests/` directory are removed; `pyproject.toml` no longer declares the app's runtime.
- [ ] **AC3 — coupling deleted:** `app/Sources/GhostlingApp/QuotaSidecar.swift`'s `SidecarProcess`
  + HTTP `QuotaPoller`, and the HTTP polling in `SessionsFeed.swift`, are removed/replaced with the
  native reader + tail. No code references `127.0.0.1:8787`.
- [ ] **AC4 — green after deletion:** `swift build` is warning-clean and `swift test` is fully
  green with the Python gone; the test counts do not shrink versus the parity matrix (no silent
  test deletion).

## Edge Cases

1. **A pytest behavior has no clean Swift home**
   - Trigger: some Python test asserts a transport detail (HTTP 404 on unknown route) that no
     longer exists.
   - Expected: that case is **explicitly dropped with a reason** in the parity matrix ("transport
     removed; N/A under file sink") — never silently. Behavioral cases must be carried; transport
     cases may be retired with a stated reason.

2. **Hidden Python consumer**
   - Trigger: a script (`.claude/scripts/*`, CI) imports `mission_control`.
   - Expected: found and updated/removed before deletion; `grep -r mission_control` returns only
     historical docs after cutover.

## Dependencies

- **Requires:** US-002 + US-003 green (the native paths must exist and be proven first).
- **Blocks:** US-001 AC1/AC2 (can't assert "no Python process" until the spawn is deleted).

## Related Decisions

- DD-001 (eliminate the sidecar). The parity-before-deletion gate is the integrity invariant
  that keeps this from being a coverage regression.

## Notes

Keep the deletion as the **last** commit of Phase 03 so a parity failure is caught while Python is
still present as a reference. The Python suite can be run side-by-side one last time to diff outputs
against the Swift reader on the same fixture before it is removed.
