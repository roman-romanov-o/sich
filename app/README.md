# Sich — macOS app (Phase 01: Terminal Foundation)

The Swift/AppKit app that **embeds libghostty and becomes the terminal** for
managed agentic-coding sessions (see `design-decisions/DD-001`). This package is
the first slice of **Phase 01 / US-001**, built directly on the Phase 00 spike
(`../spike/phase00-pty-smoke/`, verdict GO).

## What's here

| Target | Kind | Responsibility |
|--------|------|----------------|
| `GhosttyVt` | binary (xcframework) | vendored libghostty-vt; `Frameworks/ghostty-vt.xcframework` |
| `CPtySupport` | C | `forkpty()` + `execvp()` in C so the forked child never touches the Swift runtime |
| `SichCore` | Swift lib | `Terminal` (safe libghostty-vt wrapper + `lines()`), `PTYSession` (in-app PTY read + `send()`/`pollExit()`), `PoolFirewall`, `KeyEncoder`, `Session`/`SessionRegistry` |
| `SichApp` | Swift lib (AppKit) | `TerminalSurface` (renders one PTY, routes keys), the board surface (`BoardView`, `SessionCard`, `AttentionIndicator`, `DrillInPanel`, `BoardShell` — window/app lifecycle) |
| `sich-probe` | executable | runnable demo: open a session, read its pty in-process, print the screen |
| `sich` | executable (AppKit) | the launchable app: mission-control board (state columns × two-flow swimlanes + "who needs me" count + drill-in) hosting the live embedded terminal |
| `SichCoreTests` | tests | PTY-read + pool-firewall + key encoding + grid lines + registry lifecycle + **board view-model** (placement, attention, drill-in selection) |

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
swift run sich-probe                       # default echo demo
swift run sich-probe /bin/sh -c 'echo hi'  # arbitrary command
swift run sich-probe claude -p x           # refused by the firewall (exit 2)
swift run sich-app                          # windowed shell pane ($SHELL)
swift run sich-app /bin/sh -c 'echo hi'     # window hosting an arbitrary command
swift run sich-app claude -p x              # refused by the firewall before any window
swift run sich-board                        # the mission-control board, seeded with fake-agent sessions (firewall-clean)
```

## Ship a shareable build

```bash
cd app
./make-app.sh --dmg        # build/Sich.app + build/Sich-<version>.dmg
./make-app.sh --install    # also copy the bundle into /Applications
./make-app.sh --native     # arm64-only; faster, for local use — never share it
```

The default build is **universal** (arm64 + x86_64): the vendored
`libghostty-vt.a` carries both macOS slices, so an Intel Mac can run the same
bundle. `--dmg` stages the app next to an `/Applications` symlink and a
`FIRST LAUNCH — READ ME.txt`, then compresses it into a single file to hand over.

Two things make a bundle shareable rather than merely local:

- **Resources are copied into `Contents/Resources`.** SwiftPM's `Bundle.module`
  accessor falls back to the *absolute* `.build` path of the machine that
  compiled it, which is a `fatalError` on any other Mac. `BoardTheme.markURL`
  prefers the main bundle so the packaged app never consults the module bundle.
- **Gatekeeper.** There is no Apple Developer ID here, so the bundle is ad-hoc
  signed and *not* notarized; the recipient's first launch is blocked until they
  run `xattr -dr com.apple.quarantine /Applications/Sich.app` or click
  "Open Anyway" in System Settings > Privacy & Security. That is the whole of
  `FIRST-LAUNCH.txt`. Getting rid of that step requires a paid Developer ID plus
  `notarytool` — nothing else in the packaging changes.

Build output lands in `app/build/`, which is git-ignored: the artifact is
rebuildable, so hand over the `.dmg` directly (or attach it to a GitHub release)
rather than committing it.

## Dev hot reload

Sich supports DEBUG-only hot code swapping through InjectionIII:

```bash
cd app
./dev.sh
```

`dev.sh` runs `swift run -Xlinker -interposable sich`, which is the launch
mode InjectionIII needs for Swift method-body replacement. It starts
`InjectionIII.app` automatically when it is installed in `/Applications` or
`~/Applications`; select this `app/` directory in InjectionIII. If the app
bundle lives somewhere else, point Sich at its loader bundle explicitly:

```bash
SICH_INJECTION_BUNDLE=/path/to/InjectionIII.app/Contents/Resources/macOSInjection.bundle ./dev.sh
```

Hot reload is intentionally narrow: changes to method/function bodies can swap
in; adding stored properties, changing type layout, adding/removing files, or
editing C targets still needs a rebuild and relaunch.

## The Phase 03 board (US-002/003/005)

`sich-board` renders the **mission-control board**: every session as a card
placed by detected state, in **state columns × two-flow swimlanes** (Flow-A saha /
Flow-B interactive), per the HELM POC (`docs/tasks/task-01-initial/research/UI_POC.html`).
A header **"N waiting on you"** count (`AttentionIndicator`) reads quiet/zero with
no false alarm; clicking it filters the board to the waiting/blocked cards. Clicking
a card **drills into that session's embedded `TerminalSurface`** in-app (DD-001), not
an OS window jump; a back affordance returns to the board with state preserved.

The board is seeded with a spread of **fake-agent sessions** (`BoardSeed.demo`) so it
can be populated and screenshotted — each launches a harmless shell fixture through
the pool firewall (**never `claude -p`**). The pure board derivations (placement,
attention, drill-in selection) live in `SichCore` and are unit-tested; the
rendered surface and the <500 ms drill-in feel go to a human screenshot/visual
sign-off (they need a real Aqua session to paint, same as `sich-app`).

Requires the vendored xcframework's static archives — see
`Frameworks/README.md` (git-ignored; one-command rebuild).

## Window surface vs. testable seams

`TerminalSurface`/`BoardShell` (the `sich` target) render the
`libghostty-vt` screen and route keystrokes back into the pty. The on-screen
*pixel* rendering is verified by a human screenshot (it needs a real Aqua GUI
session — a CLI binary launched headlessly creates the window object and stays
on its run loop, but the window server only paints it under a logged-in
desktop). Everything that does **not** need a window is unit-tested in
`SichCore`:

- **Key event → PTY bytes** (`KeyEncoder`): ⏎, printable chars, ⌃C, arrows.
- **Grid → renderable lines** (`Terminal.lines()`): feed known output, assert lines.
- **Session lifecycle** (`SessionRegistry`): register→running, clean exit→`exited`,
  abrupt kill→`crashed` (never left `running`) — TC-E2E-104 at the logic level.

The surface's `keyDown` delegates to the same `KeyEncoder`, and `BoardShell`
launches through `SessionRegistry` so the **pool firewall** still guards the
windowed launch path (refuses `claude -p` before a window is shown).
