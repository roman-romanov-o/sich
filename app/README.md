# Ghostling — macOS app (Phase 01: Terminal Foundation)

The Swift/AppKit app that **embeds libghostty and becomes the terminal** for
managed agentic-coding sessions (see `design-decisions/DD-001`). This package is
the first slice of **Phase 01 / US-001**, built directly on the Phase 00 spike
(`../spike/phase00-pty-smoke/`, verdict GO).

## What's here

| Target | Kind | Responsibility |
|--------|------|----------------|
| `GhosttyVt` | binary (xcframework) | vendored libghostty-vt; `Frameworks/ghostty-vt.xcframework` |
| `CPtySupport` | C | `forkpty()` + `execvp()` in C so the forked child never touches the Swift runtime |
| `GhostlingCore` | Swift lib | `Terminal` (safe libghostty-vt wrapper + `lines()`), `PTYSession` (in-app PTY read + `send()`/`pollExit()`), `PoolFirewall`, `KeyEncoder`, `Session`/`SessionRegistry` |
| `GhostlingApp` | Swift lib (AppKit) | `TerminalSurface` (renders one PTY, routes keys), `AppShell` (window/app lifecycle), the Phase 03 board surface (`BoardView`, `SessionCard`, `AttentionIndicator`, `DrillInPanel`, `BoardShell`) |
| `ghostling-probe` | executable | runnable demo: open a session, read its pty in-process, print the screen |
| `ghostling-app` | executable (AppKit) | launchable single-window shell pane (the screenshottable surface) |
| `ghostling-board` | executable (AppKit) | launchable Phase 03 mission-control board: state columns × two-flow swimlanes + "who needs me" count + drill-in (the screenshottable board surface) |
| `GhostlingCoreTests` | tests | PTY-read + pool-firewall + key encoding + grid lines + registry lifecycle + **board view-model** (placement, attention, drill-in selection) |

## The two load-bearing pieces

- **In-app PTY read (US-004 keystone).** `PTYSession` spawns a child in a pty we
  own and reads its output **in-process**, feeding `libghostty-vt` — no
  AppleScript, no screen-scrape. Same path the Phase 00 spike proved, now in
  Swift through the vendored xcframework.
- **Pool firewall.** `PoolFirewall` is on `PTYSession`'s spawn path: managed
  sessions can only run **interactive** `claude` (interactive pool). It refuses
  `claude -p` / `--print` (the headless API-credit pool) structurally, not by
  convention.

## Build & test

```bash
cd app
swift build
swift test          # 40 tests: PTY read + pool firewall + key encoding + grid lines + registry lifecycle + board view-model
swift run ghostling-probe                       # default echo demo
swift run ghostling-probe /bin/sh -c 'echo hi'  # arbitrary command
swift run ghostling-probe claude -p x           # refused by the firewall (exit 2)
swift run ghostling-app                          # windowed shell pane ($SHELL)
swift run ghostling-app /bin/sh -c 'echo hi'     # window hosting an arbitrary command
swift run ghostling-app claude -p x              # refused by the firewall before any window
swift run ghostling-board                        # the mission-control board, seeded with fake-agent sessions (firewall-clean)
```

## The Phase 03 board (US-002/003/005)

`ghostling-board` renders the **mission-control board**: every session as a card
placed by detected state, in **state columns × two-flow swimlanes** (Flow-A saha /
Flow-B interactive), per the HELM POC (`docs/tasks/task-01-initial/research/UI_POC.html`).
A header **"N waiting on you"** count (`AttentionIndicator`) reads quiet/zero with
no false alarm; clicking it filters the board to the waiting/blocked cards. Clicking
a card **drills into that session's embedded `TerminalSurface`** in-app (DD-001), not
an OS window jump; a back affordance returns to the board with state preserved.

The board is seeded with a spread of **fake-agent sessions** (`BoardSeed.demo`) so it
can be populated and screenshotted — each launches a harmless shell fixture through
the pool firewall (**never `claude -p`**). The pure board derivations (placement,
attention, drill-in selection) live in `GhostlingCore` and are unit-tested; the
rendered surface and the <500 ms drill-in feel go to a human screenshot/visual
sign-off (they need a real Aqua session to paint, same as `ghostling-app`).

Requires the vendored xcframework's static archives — see
`Frameworks/README.md` (git-ignored; one-command rebuild).

## Window surface vs. testable seams

`TerminalSurface`/`AppShell` (the `ghostling-app` target) render the
`libghostty-vt` screen and route keystrokes back into the pty. The on-screen
*pixel* rendering is verified by a human screenshot (it needs a real Aqua GUI
session — a CLI binary launched headlessly creates the window object and stays
on its run loop, but the window server only paints it under a logged-in
desktop). Everything that does **not** need a window is unit-tested in
`GhostlingCore`:

- **Key event → PTY bytes** (`KeyEncoder`): ⏎, printable chars, ⌃C, arrows.
- **Grid → renderable lines** (`Terminal.lines()`): feed known output, assert lines.
- **Session lifecycle** (`SessionRegistry`): register→running, clean exit→`exited`,
  abrupt kill→`crashed` (never left `running`) — TC-E2E-104 at the logic level.

The surface's `keyDown` delegates to the same `KeyEncoder`, and `AppShell`
launches through `SessionRegistry` so the **pool firewall** still guards the
windowed launch path (refuses `claude -p` before a window is shown).
