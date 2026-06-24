# Phase 00: libghostty Embedding Spike (GATE)

**Status:** ✅ **GO** (passed 2026-06-16) — verdict + evidence in `spike/phase00-pty-smoke/RESULT.md`
**Estimated Effort:** M
**Dependencies:** none — this is the first thing built and it gates everything else.

> **Outcome:** GO. Built `libghostty-vt.a` / `.dylib` / `ghostty-vt.xcframework` from pinned `ghostty@ae52f97d` (Zig **0.15.2** — Homebrew's 0.16.0 won't build the rev). The headless smoke spawns `echo hello-ghostty` via `forkpty()`, reads the master fd **in-process**, feeds `ghostty_terminal_vt_write()`, and asserts the screen contains the line — no screen-scrape, no GUI, exit 0. The keystone in-process PTY read is proven; the Option-3 (ride-cmux) fallback is **not** needed. Correction to the planning-time risk: only **libghostty-vt + the render-state API** are required, and both are shipped/stable — what's "roadmap, not released" is a pre-baked GPU renderer / drop-in Swift widget, which we don't depend on.

## Objective

Prove, with throwaway code, that we can embed libghostty in a native macOS app, render an interactive shell, accept input, and **read the PTY in-process** — on a *pinned* libghostty revision whose embedding API is "roadmap, not released" as of 2026-06-15. This is the DD-001 Phase-0 gate: a **go/no-go** that the rest of the plan depends on.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| (none directly) — de-risks US-001 | — | M |

### Out of Scope

- Any product UI, board, quota, or state detection. This is a spike, not a feature. Throwaway code; do **not** build product architecture on it yet.

## Implementation Steps

### Step 1: Study the reference and pin a revision

**Description:** Read `ghostty-org/ghostling` (the official MVP terminal on the libghostty C API) end-to-end before writing anything. Pin a specific known-good libghostty revision.

**Technical Notes:**
- libghostty-vt (parsing/state) is shipped/stable-in-function; the rendering/input/widget layer is the risky part — that is exactly what this spike exercises.
- Record the pinned revision + build steps so the smoke test is reproducible.

**Acceptance Criteria:**
- [ ] `ghostling` build understood; pinned libghostty revision documented.

### Step 2: Minimal embed — render + input + PTY read

**Description:** A bare Swift/AppKit window hosting a libghostty surface running an interactive shell; type a command, see output; read the same output in-process.

**Files to Create/Modify (throwaway spike target):**
- `spike/GhosttyEmbedSpike/` — minimal AppKit app + libghostty C API bridge. *(Indicative path; spike is disposable.)*

**Technical Notes:**
- Honor the user's existing Ghostty config if trivially possible; if not, note the gap.
- The in-process PTY read is the load-bearing capability (it's what feeds US-004 state detection without AppleScript).

**Acceptance Criteria:**
- [x] Interactive shell renders in-app; `echo hello-ghostty` echoes and produces output. ✓ (full `ghostling` renders; smoke asserts the line)
- [x] The spike reads that output line in-process (no AppleScript / no screen-scrape). ✓ (in-process master-fd read → `vt_write` → screen assert)

**Tests:**
- TC-E2E-101 (this spike IS the test harness for the embedding smoke)

### Step 3: Go/No-Go decision

**Description:** Decide whether the embedding API is stable enough to build on.

**Acceptance Criteria:**
- [x] **GO** (taken): embedding renders/inputs/reads reliably on the pinned revision → proceeding to Phase 01; pinned revision recorded as the project baseline. ✓
- [ ] ~~**NO-GO:** Option-3 fallback (ride cmux's `/tmp/cmux.sock`), DD-005, re-plan 01–03 around the socket read~~ — **not taken** (GO).

## Definition of Done

- [x] Go/No-Go recorded with evidence (the smoke runs). ✓ `spike/phase00-pty-smoke/RESULT.md`
- [x] GO path: pinned libghostty revision + build recipe committed; in-process PTY-read smoke wired as the embedding tripwire (TC-E2E-101 seed). ✓
- [ ] ~~NO-GO path: DD-005 (fallback) written; downstream phases re-pointed~~ — n/a (GO).

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| libghostty embedding API signatures shift / unbuildable | **Medium** | **Critical** (keystone of the whole product) | Pin a revision; this spike exists precisely to find out cheaply; Option-3 fallback ready |
| Spike "works" but is fragile under upgrades | Medium | High | Treat the API as a moving target; keep the smoke test as a tripwire; don't auto-upgrade libghostty |

## Notes

- This phase makes DD-001's stated reversibility *real* rather than aspirational — failure here costs a spike, not a rewritten app.

## Related

- **Stories:** de-risks US-001
- **Decisions:** DD-001 (Phase-0 gate); DD-005 (would record an Option-3 fallback)
- **Tests:** TC-E2E-101
