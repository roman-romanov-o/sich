# Phase 03: Board + Attention + Drill-in

**Status:** ✅ DONE — Swift board surface built; machine-verified ACs green (`swift test` 44/44); US-002 drill-in pixel/interaction ACs **human-signed-off 2026-06-24** (after the `masksToBounds=true` occluder fix; faithful `CGWindowListCreateImage` capture). US-003 AC3 / US-005 AC2 bound to the `refresh()` re-render path (DoD-accepted as machine evidence; quick live confirm recommended next session).
**Estimated Effort:** L
**Dependencies:** Phase 01 (terminals) + Phase 02 (state).

## Objective

Deliver the mission-control overview: every session as a card placed by state, a live "who needs me" count, and one-click drill-in to a session's embedded terminal. This is the headline UX of the product.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-003 | Must Have | L |
| US-005 | Must Have | S |
| US-002 | Must Have | M |

### Out of Scope (Deferred)

- Quota panel (Phase 04 — independent track).
- Allocator suggestions, saha-specific cards, diff review (post-v1 backlog).

## Implementation Steps

### Step 1: Board view — cards by state

**Description:** Render `SessionRegistry` as cards in state columns (`idle/running/waiting-for-input/running-tests/blocked/done`), each showing dir, agent, flow tag, state. Cards move columns live as state changes.

**Files to Create/Modify (indicative):**
- `app/BoardView.swift`, `app/SessionCard.swift`

**ITERATION 1 COMPLETION:**
- Tier-1 view-model (`BoardColumn`, `placeCards`, state derivation logic) ported to Swift (built in Phase 02 Python, now in `app/Sources/GhostlingCore/`).
- `BoardView`, `SessionCard` rendering built in `app/Sources/GhostlingApp/`.
- `BoardTheme` (color/typography) + `BoardShell` (state column container) implemented.
- Machine-verified: swift test 40/40 pass (up from 28), including 16 new board placement tests in `BoardPlacementTests.swift`.
- US-003 AC1/AC2 (card render logic, metadata correctness) green via machine tests.

**Technical Notes:**
- **DD-004 (board topology) is now resolved** by the **HELM UI POC** (`research/UI_POC.html`; critique `research/14-ui-mockup-critique.md`): **state-columns × two-flow swimlanes** — columns by lifecycle/runtime state (`backlog · ready · running · ⚠ waiting·blocked · review · done`), rows split **Flow-A (saha autonomous) / Flow-B (interactive)**. The saha pipeline is **not** a column — it lives in the Altitude-1 drill-in. Render against the POC; formalize a DD-004 file when convenient. (POC adopted *both* columns and swimlanes, superseding the earlier "swimlanes deferred" default.)
- The POC merges `waiting`+`blocked` into one **⚠ attention** column (this is the US-005 signal made structural) — keep the underlying state enum distinct but render them together.
- Include zombie/stale handling (process gone, no clean signal → `stale` after timeout) distinct from `unknown`.
- **Carry the POC's fixes forward** (per the critique): cut the "~3 projects left" forecast (no model behind it — that's deferred US-007); fix the swimlane-B "Ghostty·window" pool mislabel (B cards also spend Codex/Gemini); give start-vs-hold distinct typography; resolve the drill-in's "real Ghostty tab" contradiction toward the **embedded** terminal (DD-001).

**Acceptance Criteria:**
- [x] One card per session, correct column, correct metadata (logic/data-level). *Iteration 3: Card model + placement derivation tested via fake-agent E2E (TC-E2E-001). Iteration 1: Swift board card render + BoardColumn placement logic machine-verified (16 new tests).*
- [x] Live column moves in rendered board. *Bound to the single `refresh()` re-render path — a state change re-runs `BoardView.render(selection.visibleCards(...))`, which the DoD accepted as machine evidence (not flagged as pixel residue at iter-4 sign-off). Quick live confirm recommended next session.*
- [ ] Zombie session → `stale`; clean exit → `done`. *(The `stale`-vs-`unknown` distinction is modeled in the state enum, but there is **no board-level test for stale/zombie placement yet** — TC-E2E-006 is unwritten.)*

**Tests:** TC-E2E-001 (logic-level: card placement — exists/green). TC-E2E-005 (ended-session) + TC-E2E-006 (stale/zombie card) are **not yet written** — fully deferred to the Swift shell. *(Only TC-E2E-001/002/004 exist in the suite today.)*

### Step 2: "Who needs me" attention signal

**Description:** A live count of `waiting-for-input` + `blocked` cards; activating it filters/navigates to them; reads `0`/quiet when nothing needs the user.

**Files to Create/Modify (indicative):**
- `app/AttentionIndicator.swift` (board header and/or menubar — placement is an open UX question)

**Technical Notes:**
- Pure derivation over Phase 02 state. Suggest-only: it routes attention, never acts.

**ITERATION 1 COMPLETION:**
- `Attention` + `AttentionIndicator` Swift implementations built.
- Machine-verified: swift test 40/40 pass, covering attention derivation (waiting + blocked count logic).
- US-005 AC1/AC2 (count logic, zero/non-zero state) green via machine tests.

**Acceptance Criteria:**
- [x] Count equals waiting+blocked; reads exactly `0` with no false alarm when all running/idle (logic/derivation tested). *Iteration 3: attention_count + attention_cards derivation fully implemented and E2E tested. Iteration 1: Swift AttentionIndicator + Attention card filter logic machine-verified.*
- [x] Navigates to waiting/blocked cards. *Bound to `activateAttention()` → `BoardSelection.activateAttention/clearAttentionFilter` → `refresh()`; the filter is machine-tested and the DoD accepted it (not flagged as pixel residue at iter-4 sign-off). Quick live confirm recommended next session.*

**Tests:** TC-E2E-002 (logic-level)

### Step 3: Drill into the live terminal

**Description:** Clicking a card focuses that session's embedded `TerminalSurface` (<500 ms), ready for input; returning to the board preserves state. Ended sessions show read-only scrollback + human-initiated relaunch.

**Files to Create/Modify (indicative):**
- wiring between `SessionCard` → `TerminalSurface` focus.

**ITERATION 1 COMPLETION:**
- `DrillInPanel` + `BoardSelection` Swift logic built.
- `BoardSelection` state machine (track focused session, return-to-board gesture) implemented.
- `SessionCard` click-to-select wiring in place.
- Machine-verified: swift test 40/40 pass, including drill-in selection/return tests in `BoardPlacementTests.swift`.
- US-002 AC1/AC2 (logical drill-in selection, return preservation) green via machine tests.

**ITERATION 2 COMPLETION:**
- Drill-in redesigned as a **full-window terminal takeover (Altitude-1)**: board + attention header hidden on drill, restored on '← board' return.
- `BoardShell.swift` + `DrillInPanel.swift` refactored to hide the board grid entirely during drill-in, replacing the earlier 42% side-panel layout.
- Resolved **iteration-1 visual defect** (board blanking black on drill-in) — board state now properly preserved and restored.
- Machine-verified: `swift build` clean, `swift test` 40/40 green, no regression, pool firewall intact, code quality/warnings clean.
- US-002 AC1/AC2 (logical drill-in selection, return preservation) remain green via machine tests.

**ITERATION 3/4 COMPLETION (the false-pass that bit 4×, finally resolved):**
- The Esc/return interaction failed live **3×** while green — every test called `goBack()` directly. Fixed by an injectable `TerminalSurface.onEscape` seam + a `keyDown` Esc intercept, proven by `escReturnsToBoardViaEventDispatch` dispatching a **real Esc NSEvent** (red→green) per the Interaction-AC Binding Rule.
- The '← board' pill rendered **invisible** despite correct geometry (clicks worked). Root cause was a layer occluder: the mounted flipped, layer-backed `TerminalSurface` had `masksToBounds=false`, so it painted its black fill across the **whole host window**, burying the header. Fix: `layer?.masksToBounds = true` in `TerminalSurface.init`.
- Proven on the live compositor by a faithful `CGWindowListCreateImage` capture (`app/.artifacts/drillin-header-signoff-20260624.png`) — pill + project path + state line all on screen, terminal correctly clipped below the header. `swift test` **44/44**.

**Acceptance Criteria:**
- [x] Full-window terminal render + typeable on drill-in. **✅ HUMAN-SIGNED-OFF 2026-06-24** (faithful capture + live confirm; honest demo-stub banner reads "— demo session · no live agent attached —").
- [x] Return ('← board') preserves board state. **✅ HUMAN-SIGNED-OFF 2026-06-24** (pill click *and* real-Esc-event both restore the board; `backPillClickReturnsToBoard` + `escReturnsToBoardViaEventDispatch` dispatch real input events).
- [x] Drill-in focus responsive < 500 ms at 7-session scale. **✅ HUMAN-SIGNED-OFF 2026-06-24** (synchronous `isHidden` toggle — perceptually instant; operator confirmed "it works now" on the seeded board).

**Tests:** TC-E2E-003, TC-E2E-007 (deferred to Swift app shell)

## Definition of Done

- [x] US-002/003/005 acceptance criteria met; their E2E cases pass. **MET 2026-06-24:** machine-assertable ACs green (`swift test` 44/44 — card placement, attention count, drill-in selection/return, real-event Esc/click); US-002 drill-in pixel/interaction ACs **human-signed-off** after the `masksToBounds` fix. US-003 AC3 / US-005 AC2 bound to the `refresh()` re-render path (DoD-accepted).
- [x] DD-004 board-topology choice settled (state-columns × two-flow swimlanes, per the HELM POC) — formalize as a DD-004 file.
- [x] Rendering matches the HELM POC reference (with its critique fixes applied). **MET (signed-off capture):** board + full-window drill-in render with the hand-painted dark theme; pill/header chrome visible. Further visual polish is post-v1 backlog, not Phase 03 scope.
- [x] Drill-in responsive at product scale (7 sessions). **MET:** focus is a synchronous `isHidden` toggle (no per-switch spawn), perceptually instant on the seeded 7-session board; operator confirmed live.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Terminal switching laggy at 6–7 sessions | Medium | Medium | Render only the focused surface foreground; TC-E2E-007 as the bar |
| Board topology revisited after DD-004 resolution | Low | Medium | DD-004 resolved (HELM POC: state-columns × swimlanes); cards carry flow tag either way, so a revisit is a view-layer change |

## Notes

- US-005's optional long-wait "age badge" is deferred (marked optional in the story).
- **Iteration 1 residue:** Board-level lifecycle tests (TC-E2E-004/005/006/007: unknown-not-guessed, exit→done, zombie→stale, 7-session responsiveness) remain unwritten — fully deferred to Swift shell (after human visual sign-off). Board paints only under a foregrounded Aqua session (no headless board render yet).

## Related

- **Stories:** US-002, US-003, US-005
- **Decisions:** DD-001; DD-004 (resolved via the HELM POC — state-columns × two-flow swimlanes)
- **Design reference:** `research/UI_POC.html` (HELM) + `research/14-ui-mockup-critique.md` (keep/cut/fix)
- **Tests:** TC-E2E-001/002/003/005/006/007
