# Task Description: Live Detection — reliable, instant terminal→board updates

**Task ID:** task-04
**Status:** Planned — Ready for Execution (stories · decisions · plan · test-specs complete; reviewed & corrected)
**Last Updated:** 2026-07-01

## Problem Statement

The board updates from agent activity **laggily and unreliably** ("ghostty
terminal updates the board quite badly"). Investigation traced the weakness to
the **detection/reconciler layer, not the terminal**: board state is a
hook-driven pipeline that is architecturally independent of the Ghostty
emulator (the emulator never contributes state — `SignalSource.pty` has no
producer). The terminal renders fine; the pipeline that turns hook events into
card-state is what feels broken.

`cmux` (`/Applications/cmux.app`, v0.64.6) was evaluated as a possible fork
base. Ground-truth inspection of its bundle + state dirs shows it is the **same
stack** (native Swift + embedded Ghostty + Claude-hook detection) — i.e. *our
architecture one maturity level ahead*, with **no board / no quota / no
mission-control**. Decision: **do NOT fork**; treat cmux as a reference
implementation and port four bounded plumbing patterns into our own codebase.
(See DD to be written; and memory `cmux-detection-is-hooks-not-terminal-scraping`.)

### Current State

Board state pipeline (source of truth = Claude Code hooks):

```
Claude hook → .claude/scripts/ghostling-forward.sh → ~/.ghostling/events.jsonl
  → HookEventTail → HookNormalizer → HookSessionStore (reconciler)
  → SessionsFeed.cards → BoardShell.applySessions
```

Five concrete weaknesses (all in the detection layer):

| # | Weakness | Location |
|---|----------|----------|
| 1 | **3s polling `Timer`** — up to 3s lag before a card moves columns | `app/Sources/GhostlingApp/SessionsFeed.swift:73` |
| 2 | **No rotation / rotation-unsafe reader** — the log grows unbounded, and `resolveStart` only resets the offset when `saved > fileSize`, so a fresh rotated file already grown past the old offset silently skips its head. *(The tail read is already incremental — `HookEventTail.poll()` seeks to a saved offset; the defect is rotation-safety, not a whole-file re-read.)* | `app/Sources/GhostlingCore/HookEventTail.swift:50` (`resolveStart`) |
| 3 | **`JSONLNormalizer` defined but never wired** — the documented dropped-hook recovery never runs live, so a lost `Stop` sticks a card in `running` forever | `app/Sources/GhostlingApp/SessionsFeed.swift:85` (only `HookNormalizer` is called) |
| 4 | **30s stale-decay guess** — a silently-dead session lingers 30s before decaying to `unknown` | `app/Sources/GhostlingCore/HookSessionStore.swift:54` |
| 5 | **Timestamp-free `projectDir` join** — when sessions share a dir, a stale `blocked`/`waiting` can out-rank a fresh `running`. The store already carries `updatedAt` (`HookSessionStore.swift:20`); the join just doesn't use it (the code's own `ponytail:` note flags it) | `app/Sources/GhostlingApp/BoardShell.swift:509` (`liveState`/`activityRank`) |

Plus: `applySessions` **suppresses board re-render while drilled into a
terminal** (`focusedCardID != nil`) — the board visibly freezes while you're
inside a session (`app/Sources/GhostlingApp/BoardShell.swift:497`).

No session persistence: `SessionRegistry` is in-memory; app restart loses all
open terminals. No Ghostty shell-integration installed, so no semantic
cwd/command signal.

### Desired State

Board state is **event-driven and reliable**:
- A hook event is reflected on the board **event-driven** (FS-watch fires the
  ingest, ≤250ms typical vs. up to 3s) — the read stays incremental (already
  does) and the log is rotation-bounded.
- A **dropped hook is recovered** (JSONL fallback wired) — cards never stick in
  the wrong column.
- The per-dir join is ordered by the **real `updatedAt`** the store already
  carries, so a fresh state always beats a stale one (`ppid` process-lineage is
  deferred — no producer, and not needed for this).
- "Needs attention" comes from an **explicit** permission event (already wired
  via `permissionRequest`), not inference.
- The board **keeps updating while drilled in**.
- App **restart restores** open terminals (cwd + session), with a
  last-known-good fallback.

## Success Criteria

Measurable outcomes that define "done":

1. [ ] A hook landing in the event log **fires the ingest via an FS-watch** (not the 3s `Timer`) — asserted deterministically that the watch fired (anti-flake), so the card updates event-driven (≤250ms typical).
2. [ ] The event reader **stays incremental** (regression-guarded — it already seeks to a saved offset, no `Data(contentsOf:)`), **survives rotation by inode**, and the log is **producer-bounded**.
3. [ ] A **dropped `Stop` hook is recovered** from the JSONL/session-lifecycle fallback: a card that would stick in `running` transitions to done — proven by a red→green test that omits the `Stop` hook.
4. [ ] When ≥2 sessions share a `projectDir`, the card shows the **freshest** session's state (ordered by the store's existing `updatedAt`), not a stale one — proven by a test with two overlapping sessions.
5. [ ] `needsAttention` is raised by an **explicit** permission event (already first-class via `permissionRequest → waitingForInput`), verified by a test that normalizes the real hook payload.
6. [ ] The board **re-renders while a terminal is focused** (drill-in no longer freezes `applySessions`).
7. [ ] After app **restart**, previously-open terminals are restored (cwd + session identity) from a versioned snapshot, with a `-previous` fallback when the current snapshot is corrupt.
8. [ ] `swift test` and `pytest` are green; every criterion above binds to a named test in the coverage matrix (no criterion left unbound).

## Scope

### In Scope

1. **Event delivery** — `DispatchSource` FS-watch on `events.jsonl` as the primary trigger, demoting the 3s poll to a backstop (DD-002 chose file-watch over a socket for our single-process case); keep the already-incremental read; make the reader rotation-safe by inode; producer-side log rotation. *(`occurred_at` already exists as `SignalEvent.timestamp`; no global `seq` — the stateless forwarder can't produce one.)*
2. **Reconciler correctness** — **wire the existing `JSONLNormalizer` fallback** (dropped-`Stop` recovery), **plumb the store's existing `updatedAt`** into the dir-join for newest-wins, and close deterministically on `sessionEnd` (relax the 30s decay to a backstop). *(Attention is already first-class via `permissionRequest`; `ppid`/`activeSessionsByWorkspace` are **deferred** — no producer, not needed for these ACs.)*
3. **Session resume** — persist the open window/pane tree (cwd + session id) to a versioned JSON snapshot (`{createdAt, version, windows}` shape) + `-previous` fallback; restore on launch.
4. **Ghostty shell-integration** — install `ghostty-integration.zsh` + `xterm-ghostty` terminfo to get semantic cwd/command boundaries (feeds detection + render).
5. Remove the **drill-in refresh freeze** (`BoardShell.swift:497`).

### Out of Scope

- **Forking cmux** — explicitly rejected; we port patterns into our codebase.
- **Multi-agent detection** (Cursor/Codex/Gemini/etc.) — separate task; see memory `cmux-detection-is-hooks-not-terminal-scraping` for the per-agent hook table.
- **Quota / capacity brain** changes.
- **New UI surfaces / board columns / redesign.**
- cmux extras we don't need now: in-app browser, split-pane tiling, PostHog/Sentry telemetry.

## Constraints

| Type | Constraint | Reason |
|------|------------|--------|
| Product | **Watcher-not-spawner** — never spawn `claude -p`; observe native sessions only. The Unix socket is local IPC for our own panes, not a way to launch agents. | Core economic/product invariant (memory `watcher-not-spawner-quota-constraint`). |
| Technical | **No fork of cmux; same stack** (Swift + `ghostty-vt` + Python hook sink). Port patterns, implement ourselves. | cmux gives no foundation we lack; forking rebuilds our differentiator on its shell. |
| Technical | Socket is **localhost/Unix-domain only**, observe-only sink stays append-only. | Keep the existing security posture; no network surface. |
| Licensing | cmux is GPL-3.0-or-later; user is fine open-sourcing the kanban under the same license, but we still **implement the patterns ourselves** (facts/interfaces, not copied code). | Clean provenance. |

## Dependencies

### Prerequisites

- [x] Detection pipeline mapped (this task's investigation).
- [x] cmux reference model captured (schema in memory + below).

### Blockers

- None. task-03-native-core is the current in-flight task; sequence task-04 after it (or branch) to avoid churn in the same Swift files.

## Technical Context

### cmux reference model (ground truth, for the porters)

- **Detection store** — `~/.cmuxterm/claude-hook-sessions.json` =
  `{activeSessionsByWorkspace, sessions{uuid→record}, version}` (persisted,
  workspace-indexed, versioned).
- **Event bus** — `~/.cmuxterm/events.jsonl`, each line
  `{seq, occurred_at, boot_id, pane_id, surface_id, window_id, workspace_id, name, category, payload, ...}`; **rotated** (`events.jsonl.1`).
- **Semantic layer** — `~/.cmuxterm/workstream.jsonl`, `kind` vocabulary =
  `toolUse | stop | userPrompt | toolResult | sessionStart | sessionEnd | question`,
  with `ppid`, `cwd`, `status`, `title`. `question` = first-class "needs-you";
  `sessionEnd` closes a workstream deterministically (no stale-timer guess);
  `ppid` binds agent→pane by process lineage.
- **Resume** — `~/Library/Application Support/cmux/session-com.cmuxterm.app.json`
  = `{createdAt, version, windows}` window/pane tree + `-previous.json`
  fallback + `cmux.sock` daemon for CLI attach.
- **Shell-integration** — bundles full Ghostty: `Resources/ghostty`,
  `xterm-ghostty` terminfo, `shell-integration/ghostty-integration.zsh`.

### Affected Components (ours)

- `app/Sources/GhostlingApp/SessionsFeed.swift` — demote 3s `Timer` (`:73`) to a backstop, add a `DispatchSource` FS-watch as the primary trigger; wire `JSONLNormalizer` (`:85`).
- `app/Sources/GhostlingCore/HookEventTail.swift` — read is *already* incremental; make `resolveStart` (`:50`) rotation-safe by keying offset-reset on inode change.
- `app/Sources/GhostlingCore/HookSessionStore.swift` — expose the existing `updatedAt` (`:20`) for the join; deterministic `sessionEnd` close, relax the 30s decay (`:54`) to a backstop. *(`ppid`/workspace-index deferred; `permissionRequest → waitingForInput` attention already wired at `:159`.)*
- `app/Sources/GhostlingApp/BoardShell.swift` — remove drill-in refresh freeze (`:497`); fix `liveState`/`activityRank` join to order by `updatedAt` (`:509`).
- `app/Sources/GhostlingCore/PTYSession.swift`, `Session.swift`, `SessionRegistry.swift` — persist/restore session tree.
- `.claude/scripts/ghostling-forward.sh` — add rotation/size-bounding (stays a stateless append-only forwarder; **no** `seq`/`occurred_at` stamping). New: shell-integration install (analogous to `enable-board-hooks.sh`).
- `app/Sources/GhostlingApp/HookInstaller.swift` — install shell-integration alongside hooks.

### Integration Points

- Existing `~/.ghostling/events.jsonl` sink (append-only, observe-only) — extended, not replaced.
- `JSONLNormalizer` (already written, currently no caller) — becomes the recovery path.
- `HookInstaller` (already installs hooks at launch) — extended to install shell-integration.

## Planning Artifacts

### Required

- [x] **User Stories** — `user-stories/` (US-001 event-driven delivery, US-002 reconciler correctness, US-003 resume, US-004 shell-integration, US-005 drill-in live refresh)
- [x] **Implementation Plan** — `implementation-plan/` (3 phases; 01+02 first — they fix the stated pain)
- [x] **Test Specifications** — `test-specs/` (AC→TC coverage matrix; every AC bound to a named symbol)

### Optional

- [x] **Design Decisions** — `design-decisions/` (DD-001 reference-not-fork, DD-002 event-delivery = file-watch, DD-003 reconciliation = timestamp-first)
- [x] **Research Report** — cmux model captured above (ground truth from the local bundle); no separate report needed.
- UI Design — **not needed** (no new UI surface).

## Open Questions

- [x] Socket push vs. `DispatchSource` file-watch on `events.jsonl` — **resolved in DD-002: file-watch.** A socket buys nothing for our single-process case (cmux needs it only for its cross-process CLI).
- [ ] Rotation policy: size threshold + retained generations (cmux keeps `.1`).
- [ ] Does relaxing the 30s stale-decay risk stuck cards if `sessionEnd`/process-exit is missed? Keep a longer backstop decay.
- [ ] Where to persist the session snapshot for a SwiftPM app (Application Support path).

## References

- cmux app: `/Applications/cmux.app` (v0.64.6); state: `~/.cmuxterm/`, `~/Library/Application Support/cmux/`.
- Memory: `cmux-detection-is-hooks-not-terminal-scraping` (fork verdict + full schema), `real-prototype-assembled-data-paths-live` (current pipeline), `watcher-not-spawner-quota-constraint`, `dd-001-embed-libghostty-decision`.
</invoke>
