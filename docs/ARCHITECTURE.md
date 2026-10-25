# Architecture

Sich is a native macOS/AppKit app (Swift 6, `app/`) that embeds
libghostty to become the terminal for managed agentic-coding sessions, with
a kanban board and quota panel wrapped around it. It is a single binary:
there is no helper service, no sidecar process, and no HTTP wire.

## Package layout (`app/Package.swift`)

- **GhosttyVt** — vendored `ghostty-vt.xcframework` binary target (libghostty).
- **CPtySupport** — C target for `fork()`/`execvp()`. Kept in C so the child
  process between fork and exec never touches the Swift runtime
  (async-signal-safety).
- **SichCore** — testable, headless logic: PTY session management,
  terminal grid/rendering model, session registry, quota gauge, pool
  firewall, hook-event parsing. No AppKit dependency.
- **SichApp** — AppKit layer: windows, board/quota views, drill-in
  terminal surface, hook installer. Depends on SichCore; keeps views
  thin, pushes logic down into Core.
- **sich-probe** — small executable for headless smoke-testing Core.
- **sich** — the one shipped product binary: board + quota side panel +
  drill-in terminal in a single window.
- Test targets: `SichCoreTests`, `SichAppTests`.

## Core concepts

### Board altitude, two Anthropic pools
The board tracks agentic-coding work at "board altitude": one card per
session, placed by the agent's detected state. Quota is read per pool
(interactive subscription vs. API credits) and the two are never summed.

### Watcher, not spawner
`PoolFirewall` (`SichCore/PoolFirewall.swift`) enforces in code that
the app never programmatically spawns headless `claude -p` calls — it only
observes real interactive sessions the user starts themselves. This is a
hard economic constraint from Anthropic's quota split, not a style
preference.

### Embedded terminal (DD-001)
Rather than shelling out to an external terminal emulator, the app embeds
libghostty directly (`Terminal`, `TerminalGrid`, `PTYSession` in
SichCore; `TerminalSurface` in SichApp) and does the PTY read
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
`NativeQuotaPoller` (`SichApp/QuotaSidecar.swift`) reads each Claude
profile's usage in-process — `ClaudeUsageProbe` hits the real
`/api/oauth/usage` endpoint with the keychain OAuth token, and
`QuotaUsageReader` walks the transcript directories — then hands
`[QuotaSourceInput]` to `QuotaPanel`. Codex, Cursor and Antigravity have
their own readers next to it.

### Remote sessions
A remote card attaches a tmux session over ssh (`RemoteTmuxCommand`,
`RemoteEventRelay`). The relay tails the far side's hook event log so a
remote agent moves its card exactly like a local one; `RemoteHookInstallState`
tracks whether the forwarder is installed there.

## Data flow (running app)

1. `BoardShell` (NSApplicationDelegate) boots the window and installs global
   Claude hooks. It owns the main window's board + quota + drill-in
   composition and runs the always-on PTY pump (drains every session's PTY
   except the one currently drilled into, avoiding PTY back-pressure
   deadlocks).
2. Hook events land via `HookEventTail`, get normalized, and update
   `SessionRegistry` / `BoardColumn` state, moving cards across the board.
3. `NativeQuotaPoller` polls quota data in the background and feeds
   `QuotaPanel`/`QuotaGaugeRow`.
4. Selecting a card drills into its `TerminalSurface` inside `DrillInPanel`,
   a full-window takeover of the same PTY the board was draining.

## Docs map

- `docs/PRODUCT.md` — product thesis and constraints.
- `docs/OPERATING-RULES.md` — pace and attention rules (rule 1 is enforced in-app).
- `docs/CARD-STATUS.md` — the exact rules that move a card between columns.
- `docs/further-ideas.md` — backlog of ideas not yet scoped.
