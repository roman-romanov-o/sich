# task-01-initial — Build Status

**Updated:** 2026-06-24 (Phase 03 **DONE — drill-in human-signed-off after the invisible-header occluder fix; `swift test` 44/44**)
**Phase 03 sign-off (2026-06-24):** The drill-in header ('← board' pill + project path + state line) shipped green but **invisible** on the live app 4×. Root cause: the mounted flipped, layer-backed `TerminalSurface` had `masksToBounds=false`, so it painted its black fill across the **whole host window**, burying the header (geometry/hit-testing were always correct — clicks worked while pixels were hidden). **Fix:** `layer?.masksToBounds = true` in `TerminalSurface.init`. Proven on the live compositor by a faithful `CGWindowListCreateImage` capture (`app/.artifacts/drillin-header-signoff-20260624.png`), then **human-confirmed live ("it works now")**. The Esc-returns interaction (3 prior false passes) is now proven by a real dispatched Esc `NSEvent` (`escReturnsToBoardViaEventDispatch`) + a real `leftMouseDown` on the pill (`backPillClickReturnsToBoard`). `swift build` clean, `swift test` **44/44**, pytest **59/59**, pool firewall intact, 13/13 frozen specs unchanged. **US-002 drill-in pixel/interaction ACs human-signed-off; US-003 AC3 / US-005 AC2 bound to the `refresh()` re-render path (DoD-accepted).** Board-level lifecycle tests (TC-E2E-005/006: ended-session, zombie→stale card placement) remain unwritten — deferred.
**Iteration 2 outcome:** Drill-in redesigned as a full-window terminal takeover (Altitude-1): board + attention header hidden on drill, restored on '← board' return. `BoardShell.swift` + `DrillInPanel.swift` refactored to hide board grid during drill-in. Resolved iteration-1 visual defect (board blanking black). Machine-verified: `swift build` clean, `swift test` 40/40 green, pool firewall intact.
**Iteration 1 outcome:** Phase 03 board surface (BoardView, SessionCard, AttentionIndicator, DrillInPanel, BoardSelection logic) built in Swift. Tier-1 view-model (BoardColumn card placement, Attention derivation, drill-in state machine) ported from Python core. Machine-assertable acceptance criteria green (US-003 AC1/AC2, US-005 AC1/AC2, US-002 AC1/AC2 logical drill-in selection/return). `swift test` **40/40 green** (12 tests new for board).

**Prior phases:**
Phase 01 **complete + fully human-approved**; windowed surface
built, Ctrl-D lifecycle-presentation fix landed *and* visually re-confirmed — `swift test`
**28/28** green. All US-001 ACs human-confirmed; no pixel residue remains.
Phase 00 (the libghostty embedding gate) **passed autonomously — verdict GO** (see `spike/phase00-pty-smoke/RESULT.md`). **Phase 01 (Terminal Foundation, US-001):** a Swift package (`app/`) vendors `ghostty-vt.xcframework`,
does the in-app in-process PTY read in Swift, renders an interactive `NSView` shell pane
(`AppShell` + `TerminalSurface`), and enforces the pool firewall in code — `swift test`
green (**28 tests**). US-001 AC1 (the shell renders, legibly + interactively) was **human
visual-approved 2026-06-17**. Iteration 2 then fixed a lifecycle-presentation defect found
during that sign-off (a Ctrl-D/EOF logout carrying a non-zero `$?` was mislabeled
"crashed" and the window read as stuck) via a pure, window-free `SessionDisposition` seam.

## TL;DR

A working, fully-tested **Python sidecar** now exists — the logic core the Swift/libghostty
app will consume. **50 tests pass; ruff / ty / complexipy all clean.** No quota was spent
(no `claude -p`, no network, no live agent — all tests run on recorded fixtures + an
in-process fake-agent). What's *not* here is the macOS app itself (terminal, board
rendering, drill-in) — that's gated on the Phase 00 libghostty embedding spike.

## What is built + verified (this repo)

| Area | Module | Backs | Tests | Status |
|------|--------|-------|-------|--------|
| Two-pool quota | `mission_control.quota` (`models`, `window_math`, `aggregator`, `sources/`) | Phase 04 / US-006 | 9 unit + 5 integration | ✅ logic complete + green |
| State detection | `mission_control.detector` (`events`, `classifier`, `hook_receiver`, `jsonl_tail`, `reconciler`, `registry`) | Phase 02 / US-004 | 21 unit + 8 integration | ✅ logic complete + green |
| Board derivations | `mission_control.board` (`card`, `placement`, `attention`) | Phase 03 / US-003, US-005 | covered via E2E | ✅ logic complete + green |
| Fake-agent E2E harness | `tests/fixtures/fake_agent.py` + `tests/e2e/` | quota-safe test backbone | 7 e2e | ✅ green |

**Spec coverage:** TC-UNIT-001..003 (+ full classifier table), TC-UNIT-101..104 (+ table),
TC-INT-001..004 (state detection), TC-INT-101..104 (quota aggregation), TC-E2E-001/002/004
(board, logic-level). All green.

**Conventions honored:** Pydantic V2, module-level imports only, functions ≤ 50 lines,
single-responsibility, deterministic (every clock is injected — no system-clock reads in
logic), no over-mocking (the fake-agent drives the *real* reconciler → registry → board
pipeline, never hand-sets states).

### Run it

```bash
uv sync --extra dev
uv run pytest -q          # 50 passed
uv run ruff check src tests
uvx ty check src
uvx complexipy src
```

## Phase 00 — libghostty embedding spike: **GO** (2026-06-16)

Attempted and passed autonomously. Full record: `spike/phase00-pty-smoke/RESULT.md`.

- **Builds from a pinned rev** (`ghostty@ae52f97d`, Zig **0.15.2**) → `libghostty-vt.a`,
  `.dylib`, **and `ghostty-vt.xcframework`** (Swift/Xcode-ready, macOS + iOS slices).
- **Headless in-process PTY read proven:** `spike/phase00-pty-smoke/` spawns
  `echo hello-ghostty` via `forkpty()`, reads the master fd in-process, feeds
  `ghostty_terminal_vt_write()`, and asserts the screen contains the line — no
  screen-scrape, no GUI. Exit 0.
- **Full `ghostling` terminal renders** (libghostty render-state API + OpenGL).
- Correction: only **libghostty-vt + the render-state API** are needed and they are
  *shipped/stable*; what's "roadmap, not released" is a pre-baked GPU renderer / drop-in
  Swift widget, which we don't require.

## Phase 01 — Terminal Foundation (US-001): **built + human-approved** (2026-06-20)

Swift package at `app/` (`swift build` + `swift test` clean — **28 tests**). See `app/README.md`.

- **Vendored** `ghostty-vt.xcframework` as a SwiftPM binary target (`GhosttyVt`); its
  static archives are git-ignored with a one-command rebuild (`app/Frameworks/README.md`).
- **In-app PTY read, in Swift** — `PTYSession` spawns a child in a pty we own and reads its
  output **in-process** into a `libghostty-vt` `Terminal` (the US-004 keystone, ported from
  the C spike). `fork()`/`execvp()` live in a tiny C target (`CPtySupport`) so the forked
  child never touches the Swift runtime.
- **Windowed interactive surface** — `TerminalSurface` (an `NSView`) renders the
  `libghostty-vt` screen and routes keystrokes back into the pty; `AppShell` hosts it in a
  window via `ghostling-app`. **Human visual-approved 2026-06-17** (legible, interactive,
  echo + Ctrl-C + arrows work).
- **Clean lifecycle presentation (iter 2)** — `SessionDisposition` is a pure, window-free
  seam that splits the registry's coarse `.crashed(ProcessExit)` by payload: a terminating
  **signal** → `crashed(signal)` (the only true crash, per TC-E2E-104); a **WIFEXITED**
  with any code → `exited(code)` (a clean exit, per US-001 Edge Case 2). The surface shows
  a dim "— session ended (exit N) —" banner instead of freezing, and the window title reads
  `[exited]` not `[crashed]` for a Ctrl-D logout. The frozen registry classification is
  untouched — the fix lives entirely in the presentation layer.
- **Pool firewall, in code** — `PoolFirewall` sits on `PTYSession`'s spawn path: interactive
  `claude` only; `claude -p` / `--print` is refused structurally (verified by tests + the probe).
- **`ghostling-probe`** — a runnable headless demo of the whole path.

## What is still not built (Swift/AppKit app surface)

These remain unbuilt — but Phase 00 GO + the Phase 01 core mean they are **unblocked**:

| Phase / Story | Status |
|---------------|--------|
| **Phase 01 — windowed terminal *surface*** | ✅ **Built + human-approved** (`TerminalSurface` + `AppShell`, render approved 2026-06-17; Ctrl-D lifecycle presentation fixed iter 2). Remaining polish (not Phase 01 scope): the simple monospaced `Terminal.lines()` draw could later become a GPU glyph renderer. |
| **Phase 03 — rendering / drill-in (US-002, US-003, US-005)** | ✅ **DONE (2026-06-24).** `swift test` 44/44, build + quality clean. Invisible-header occluder fixed (`TerminalSurface.masksToBounds=true`); Esc/click return proven by **real dispatched input events**. US-002 drill-in pixel/interaction ACs **human-signed-off** (faithful capture + live confirm); US-003 AC3 / US-005 AC2 bound to the `refresh()` re-render path (DoD-accepted). Lifecycle card-placement tests TC-E2E-005/006 still deferred. |
| **Live wiring for Phase 02** | ✅ **HTTP receiver endpoint (Python) built + verified (iter 3)** — `src/mission_control/server/{endpoint, ingest, __main__}` + 59 pytest green. Remaining: app-side PTY-feed binding into Swift shell (gated on Phase 03 rendering). |
| **Phase 04 — `QuotaPanel.swift` gauges** | Rendering the (already-built) `PoolGauge` data into AppKit gauges. |

## How the Swift app consumes this sidecar

The sidecar is pure logic with stable, typed seams:
- The app feeds Claude Code hook payloads / JSONL lines / PTY signals to
  `detector.hook_receiver.normalize_*` and `detector.jsonl_tail.normalize_jsonl`, runs them
  through `StateReconciler` (injecting wall-clock `now`), and reads session state from
  `SessionRegistry`.
- The board renders `board.placement.place(cards)` columns and shows
  `board.attention.attention_count(cards)` as the "who needs me" badge.
- The quota panel renders `quota.QuotaAggregator.gauges()` — two independent Anthropic
  pools (never netted), with `Confidence.ESTIMATED` marking inferred values.

## Recommended next action

1. ~~Run the Phase 00 libghostty spike~~ — **done, GO** (`spike/phase00-pty-smoke/RESULT.md`).
2. ~~Stand up the Swift package, vendor the xcframework, bind the in-app PTY read + pool firewall~~ — **done** (`app/`, `swift test` 28/28 green).
3. ~~Phase 01 surface: AppKit NSView rendering + interactive terminal pane~~ — **done** (`TerminalSurface` + `AppShell`), human visual-approved 2026-06-17.
4. ~~Phase 03 board surface + attention + drill-in~~ — ✅ **done + human-signed-off 2026-06-24** (`swift test` 44/44; invisible-header occluder fixed; Esc/click return proven by dispatched input events).
5. **▶ NEXT (`/saha:execute task-01-initial`): Phase 04 — `QuotaPanel.swift` gauge rendering.** The quota logic core is built + green; this is Swift/AppKit rendering of `PoolGauge` data into four distinct, never-netted gauges (+ TC-E2E-201..204). See `implementation-plan/phase-04-two-pool-quota.md`.
6. Wire the Phase 02 HTTP hook endpoint (Python side built + verified) into the Swift shell so detector state flows from real sessions.
7. (Optional cleanup) Write the deferred board-lifecycle card-placement tests TC-E2E-005/006.

## Note on verifying the Swift/libghostty work

The earlier claim that this surface "can't be built or verified in a headless loop" was
overstated. The Phase 00 spike was built and verified autonomously (programmatic assertion
on the in-process PTY read). The genuine constraints were narrower: a pinned **Zig 0.15.2**
toolchain (Homebrew's 0.16.0 won't build the pinned rev) and a GUI session for the *rendered*
window (present here). The saha QA/quality agents default to Python tooling (pytest/ruff/ty/
complexipy); Swift/C verification needs them to also run `swift build` / `xcodebuild` / a
smoke like this spike — a tooling gap, not a "needs a human" wall.
