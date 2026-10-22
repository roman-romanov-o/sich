# Sich architecture review — speed and quality (2026-09-02)

Scope: the whole `app/` Swift package on branch `checklist-fixes-aug04`
(11 unmerged commits + 62 dirty files at review time). Every finding below
was verified by reading the cited code, not only reported by the audit
agents. Ranked by what the user feels, most painful first.

Architecture map (as found):

- Render: PTY drained entirely on the main thread. Drilled-in card =
  `DispatchSourceRead` on `.main` + a 60/4 Hz `Timer`
  (`TerminalSurface.startReading`). Every other card = one shared 60/4 Hz
  `Timer` pump in `BoardShell.pumpBackgroundSessions`. Each frame calls
  `Terminal.snapshot()` (full viewport re-extract), diffs rows by array
  equality, then `NSView.draw(_:)` with `NSString.draw` per colour run.
  Frame clock = `NSView.displayLink` in `TerminalFrameCoordinator`.
- Board state: `BoardShell.swift` (3019 lines) owns window lifecycle, card
  CRUD, pump, persistence, remote probes, quota, planning, archive,
  notifications. ~8-10 overlapping holders of card state.
- Persistence: `BoardTaskStore.save` = synchronous atomic pretty-printed
  JSON write of the whole book (backlog + board + archive) on the main
  actor on every mutation, wrapped in `try?`.
- Hook ingestion: `~/.sich/events.jsonl` tail (`FileWatcher` on main) +
  3 s backstop poll in `SessionsFeed`; `HookSessionStore` never prunes;
  `RemoteEventRelay` (`ssh tail -F`) reconnects every 5 s forever.
- Quota: `QuotaSidecar` 15 s tick → `Task.detached(.utility)`;
  `TUIUsageProbe` hidden-PTY `/usage` scrape every 5 min per agent.
- Tests: 139 files, ~781 tests; Sources build warning-free, Tests carry
  156 warnings (126 unnecessary `try`); CI retries `swift test` once for
  the known PTY-EOF flake.

## A. Speed — the drill-in terminal (main-thread CPU, input lag)

1. **Link regexes on every repainted row, every frame.** `drawRow` →
   `drawLinkUnderlines` rebuilds the row string and runs two
   `NSRegularExpression`s over it (`app/Sources/SichApp/TerminalSurface.swift:627-645`,
   `app/Sources/SichCore/TerminalLinks.swift:44-62`). ~1-3 ms per full
   repaint. Fix: cache links per row keyed by row content hash, or detect
   lazily on ⌘-hover / click only.
2. **Per-row damage collapses to one union rect.** The view is layer-backed
   (`TerminalSurface.swift:88`) and `draw(_:)` never reads
   `getRectsBeingDrawn`, so cursor move + status line = full-screen repaint
   (`TerminalSurface.swift:298-304, 590-609`). Fix: read the rect list, or
   keep an explicit dirty-row set and draw only those rows.
3. **`NSString.draw` per colour run, no glyph/CTLine cache**
   (`TerminalSurface.swift:690`). A colourful Claude screen = 1000+
   typesetter passes per frame. Fix: monospace + zero kerning → resolve
   glyphs once per (scalar, style) into a cache and draw with
   `CTFontDrawGlyphs` at `col × cellWidth`.
4. **Full grid re-extracted every frame.** `RenderState.snapshot(from:)`
   builds a fresh `[TerminalCell]`, `readRow` allocates a per-row array,
   `readCell` makes 4 FFI calls per cell
   (`app/Sources/SichCore/TerminalGrid.swift:124-206`). Fix: preallocated
   buffer, drop the intermediate array, keep a per-row hash and diff hashes
   instead of cell arrays.
5. **Contrast bisection runs before the cache lookup.** `glyphAttrs` calls
   `ContrastColor.adjusted` (pow-based luminance, 20-step bisection) and
   then keys the cache on the adjusted colour
   (`TerminalSurface.swift:815-839`, `ContrastColor.swift:30-62`). Fix: key
   on raw (fg, bg, style).
6. **`ClaudeTheme.install` does JSON + disk IO on every surface init and
   font change** (`TerminalSurface.swift:116-121`, `ClaudeTheme.swift:88-96`).
7. **Held-output flush can be a 2 MB synchronous write after a selection
   ends** (`PTYSession.swift:79-104`).
8. **10 MB scrollback per session, unbounded aggregate**
   (`Terminal.swift:22`); `syncTerminalSize` writes UserDefaults + full
   refresh on every `setFrameSize`.

## B. Speed — the board with many cards

9. **Any hook event rebuilds every card view in the column.** The column
   diff key `CardFace{card, chip}` uses the whole `BoardCard`, whose
   synthesized `==` includes `updatedAt`
   (`app/Sources/SichApp/BoardView.swift:305-362`,
   `app/Sources/SichCore/BoardCard.swift:123`). So the face-diff fix from
   the "many-tasks slowdown" commit rarely fires for the WORKING column;
   each rebuild allocates timers, CAAnimations, tracking areas and a layout
   pass per card. Fix: exclude timestamps from the face key; update
   existing card views in place by id.
10. **Task book written synchronously on main at pump cadence.**
    `persistTasks` pretty-prints the whole book incl. archive and writes
    atomically (`BoardShell.swift:649-655`, `TaskStore.swift:185-196`);
    the Codex screen scrape can trigger it every tick. Fix: debounce
    (~250 ms), write off main, split the archive into its own file.
11. **Codex choice-screen scrape formats the full screen up to 60×/s per
    card** (`BoardShell.swift:393, 413-425`). Fix: throttle to 2-4 Hz wall
    clock.
12. **Background pump has no per-tick budget.** 64 KB per session per tick
    plus two `fcntl` calls per session per tick
    (`BoardShell.swift:349-407`). Fix: global byte budget with round-robin;
    hoist `setNonBlocking` to spawn; longer term move drains to per-fd
    `DispatchSource`s off main.
13. **Memory grows for the app lifetime.** `HookSessionStore` never
    prunes; `SessionsFeed` keeps every turn diff; dedup SHA-256 over
    multi-MB lines under a lock.

## C. Quality — hangs and data loss

14. **Blocking ssh on the main actor.** `remoteSessionConflict` /
    `remoteSessionIsLost` call `RemoteSessionProbe.presence` synchronously
    (`BoardShell.swift:~1996-2005, ~2574-2578` →
    `RemoteSessionKey.swift:78-86` → `SSHCommandRunner.bounded`), 10 s
    deadline. After the deadline the runner does an unbounded
    `finished.wait()` and the stdin write is unbounded too
    (`RemoteHookInstallState.swift:160-198`), so a grandchild holding
    stdout hangs the app for good. Fix: make the probes async (pattern
    exists in `RemoteHookStatus.offMainThread`), bound every wait, close
    the pipes on timeout.
15. **Unparsable `~/.claude/settings.json` is silently replaced.**
    `config(from:)` returns `[:]` on any parse error; `writeConfig` then
    overwrites non-atomically with no backup
    (`app/Sources/SichApp/HookInstaller.swift:410-427`). Fix: refuse to
    write when the existing file is non-empty and unparsable; write
    atomically; keep a `.bak`.
16. **Persistence failures are invisible.** Task-book save is `try?`
    (172 `try?` sites in Sources). Fix: one-shot banner on first failed
    write; log the error.
17. **Zombie + fd leaks.** `terminate()` forgets the pid after 100 ms
    (tracked separately in task-100); `PTYSession` has no `deinit`; the
    read `DispatchSource` is cancelled asynchronously before the fd is
    closed elsewhere (`TerminalSurface.swift:181-208`) → a recycled fd can
    deliver another session's bytes. Fix: close the fd in the cancel
    handler; `deinit { terminate() }`.
18. **Remote relays retry every 5 s forever and are never stopped**
    (`RemoteEventRelay.swift:~189`); health stays "connecting". Fix:
    exponential backoff with a cap, stop relays when the last card for a
    host is removed, surface the failure on the host chip.
19. **Other silent failures:** restored pane vanishes if
    `PoolFirewall.classify` throws; `drill(into:)` guard-returns with no
    feedback; two force-unwraps in `HookSessionStore` (`dominant`,
    `applyBurst`); `SessionsFeed` index/1000 timestamp ordering hack breaks
    at >1000 lines per batch; `FileWatcher` never armed if
    `events.jsonl` is absent at launch.
20. **Quota/remote minor:** `QuotaUsageReader.fileCache = next` replaces
    (not merges) per profile in the estimate fallback branch only
    (`QuotaUsageReader.swift:200-213`); `CodexUsageReader` walks the
    sessions dir twice per tick; `QuotaPanel.render` rebuilds all views
    every 15 s; `TUIUsageProbe` spawns a login shell + full agent every
    5 min with a 75 s busy-poll; `UsageEndpointReader` has no request
    timeout; `DiffTextView.render` lays out up to 1.5 MiB on main;
    `LikeC4.build` has no timeout and is not killed on teardown;
    `SahaPlanStatusRunner` never drains stderr (latent deadlock, dormant).

## D. Architecture

21. **`BoardShell` god object.** Card state lives in: `cards[].state`,
    `HookSessionStore` entry, `manuallyDoneCardIDs`,
    `codexChoiceWaitingCardIDs`, `idleHoldUntil`, registry state,
    `TaskRecord.placement`, `PaneSnapshot.cardState`, `lastCardStates`.
    Highest-value extraction: a pure `CardStateReducer`
    (detector state × manual override × process liveness × link health →
    `CardState`). Then `TaskPersistence` (debounced, off-main),
    `TerminalPumpCoordinator`, `RemoteCardCoordinator`.
22. **`refresh()` mixes render with side effects** (notifications, badge,
    work log) so a redraw can re-notify. Cheap first cut: split `render()`
    from `reconcileNotifications()`.

## E. Process

23. Tests: 156 warnings all in Tests (126 unnecessary `try`), 27 fixed
    `Thread.sleep` sites, CI retries the suite once, real-agent E2E dark by
    default (`SICH_REAL_AGENT_E2E=1`).
24. Branch: 11 unmerged commits + 62 dirty files (~2200 uncommitted lines)
    on `checklist-fixes-aug04` — most likely way work gets lost.
25. Positive: `RemoteTmuxCommand` quoting/validation is sound (no injection
    found); Sources compile warning-free under Swift 6 strict concurrency.

Suggested starting order (each under a day, biggest visible pain first):
9, 1, 10, 14, 15.
