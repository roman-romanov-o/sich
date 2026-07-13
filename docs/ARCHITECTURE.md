# Architecture

Ghostling is a native macOS/AppKit app (Swift 6, `app/`) that embeds
libghostty to become the terminal for managed agentic-coding sessions, with
a kanban board and quota panel wrapped around it. There is no separate
Python service in the running product — the earlier Python core was
retired; a tiny Python "sidecar" process is spawned locally only to serve
`/quota` and `/sessions` JSON to the app (see below).

## Package layout (`app/Package.swift`)

- **GhosttyVt** — vendored `ghostty-vt.xcframework` binary target (libghostty).
- **CPtySupport** — C target for `fork()`/`execvp()`. Kept in C so the child
  process between fork and exec never touches the Swift runtime
  (async-signal-safety).
- **GhostlingCore** — testable, headless logic: PTY session management,
  terminal grid/rendering model, session registry, quota gauge, pool
  firewall, hook-event parsing. No AppKit dependency.
- **GhostlingApp** — AppKit layer: windows, board/quota views, drill-in
  terminal surface, hook installer. Depends on GhostlingCore; keeps views
  thin, pushes logic down into Core.
- **ghostling-probe** — small executable for headless smoke-testing Core.
- **ghostling** — the one shipped product binary: board + quota side panel +
  drill-in terminal in a single window.
- Test targets: `GhostlingCoreTests`, `GhostlingAppTests`.

## Core concepts

### Two-flow / two-pool board
The board tracks agentic-coding work at "board altitude" across two
Anthropic usage pools (interactive `claude` sessions vs. API-credit `saha
run`). It is a cockpit for the `saha` planning/execution loop, not a
generic kanban.

### Watcher, not spawner
`PoolFirewall` (`GhostlingCore/PoolFirewall.swift`) enforces in code that
the app never programmatically spawns headless `claude -p` calls — it only
observes real interactive sessions the user starts themselves. This is a
hard economic constraint from Anthropic's quota split, not a style
preference.

### Embedded terminal (DD-001)
Rather than shelling out to an external terminal emulator, the app embeds
libghostty directly (`Terminal`, `TerminalGrid`, `PTYSession` in
GhostlingCore; `TerminalSurface` in GhostlingApp) and does the PTY read
in-process. `KeyEncoder` translates NSEvent keystrokes into PTY input.

### Session detection via hooks
Claude Code sessions running in *other* terminals are surfaced on the
board through per-agent hook installers (`HookInstaller`,
`HookEventTail`/`HookNormalizer`/`HookSessionStore` in Core), not by
scraping terminal output. `HookInstaller.installGlobal()` wires Claude's
hooks at launch so board-card state (waiting/running/done) tracks real
session lifecycle. Sessions owned by the app's own embedded terminal and
sessions observed via hooks are merged into one `SessionRegistry`.

### Quota panel
`QuotaSidecar` spawns a lightweight local process that reads Claude's real
`/api/oauth/usage` endpoint (via the keychain OAuth token) and exposes it
as `/quota` and `/sessions` JSON, which `QuotaGauge`/`QuotaUsageReader`
poll. This replaced an earlier token-count estimate that read ~2x high.

### Diffs / drill-in
Per-turn diffs shown in the drill-in panel (`DiffModel`, `DiffTextView`,
`ChangesView`, `DrillInSidebar`) are git-sourced and rendered with a native
`NSTextView` + stdlib word-diff — no webview, no remote/tmux dependency.

## Data flow (running app)

1. `AppShell` (NSApplicationDelegate) boots the window and installs global
   Claude hooks.
2. `BoardShell` owns the main window's board + quota + drill-in
   composition and runs the always-on PTY pump (drains every session's PTY
   except the one currently drilled into, avoiding PTY back-pressure
   deadlocks).
3. Hook events land via `HookEventTail`, get normalized, and update
   `SessionRegistry` / `BoardColumn` state, moving cards across the board.
4. `QuotaSidecar` polls quota/session data in the background and feeds
   `QuotaPanel`/`QuotaGaugeRow`.
5. Selecting a card drills into `TerminalSurface` (if it's the owned
   embedded terminal) or `DrillInPanel`/`DrillInSidebar` for diffs and
   history.

## Docs map

- `docs/PRODUCT.md` — product thesis and constraints.
- `docs/DESIGN-SPEC.md` — UI/interaction spec.
- `docs/further-ideas.md` — backlog of ideas not yet scoped into a task.
- `docs/tasks/task-XX-*/` — Sahaidachny task planning artifacts (user
  stories, plans, decisions) per feature.
