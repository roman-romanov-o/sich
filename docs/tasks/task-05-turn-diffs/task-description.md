# Task Description: Per-Turn Diff Review in Drill-In

**Task ID:** task-05
**Status:** Draft
**Last Updated:** 2026-07-04

## Problem Statement

Tools like T3Code and the OpenAI Codex app make agent code review pleasant: they
show what the agent changed **per turn**, in a clean, scannable diff UI. Our
board embeds the real interactive terminal (DD-001, watcher-not-spawner), so the
human already *sees* the agent work — but there is no dedicated, reviewable view
of the resulting code changes. Scrolling terminal scrollback is not a review
surface.

We want the same "review the last turn's changes" ergonomics **without betraying
the stack**: no webview, no SDK-wrapper, no re-plumbing the agent through an API.
The terminal stays real libghostty; the diff is read-only chrome next to it (same
category as the quota panel).

### Current State

- Drill-in (`DrillInPanel`) shows the live terminal for a session and (task-04)
  live state detection driven by installed Claude hooks
  (`UserPromptSubmit`/`Stop`/`SessionEnd`, via `HookInstaller`).
- No view of code changes. Reviewing a turn means reading terminal scrollback.
- Sessions may run **locally** or **remotely** (tmux over a tailnet); remote
  sessions already reach the board over the tailscale channel.

### Desired State

- Drill-in gains a **"Changes" tab** rendering the diff of what the agent changed,
  scoped to a **turn** (default: last turn), with a picker to view earlier turns
  or the whole session.
- Rendering is **fully native Swift/AppKit** — `NSTextView` + attributed strings,
  word-level intra-line highlighting via stdlib `CollectionDifference`. No webview.
- Works identically for local and remote/tmux sessions because the diff travels
  as **data (unified-diff text)**, computed by the hook on the machine where the
  repo lives — the board never touches the remote filesystem.

## Success Criteria

1. [ ] Drill-in has a Changes tab showing the last turn's `git diff` for the
       session's repo, updated when a turn ends.
2. [ ] A turn picker lets the user view any recorded turn or the full session diff.
3. [ ] Intra-line (word-level) changes are visually highlighted using stdlib diff.
4. [ ] Remote (tmux/tailscale) sessions render diffs via the same event path as
       local, with no filesystem access from the board host.
5. [ ] Rendering is native AppKit — no WKWebView, no new rendering dependency.
6. [ ] Diff parser + word-diff + renderer each covered by `swift test`.

## Scope

### In Scope

- Hook-side turn checkpointing: `git stash create` (+ `git add -N .` for untracked)
  at turn start, `git diff <checkpoint>` at turn end, POSTed as a `turn_diff` event.
- Receiver + registry: store per-session ordered list of turn diffs (raw unified
  text + stats).
- Swift unified-diff parser (`DiffFile → [Hunk] → [Line]`).
- Word-level highlighting via `Collection.difference(from:)`.
- `NSTextView`-based diff renderer: line +/- background tints, word-level
  emphasis, mono font, BoardTheme colors; per-file collapsible headers.
- Changes tab + turn picker in `DrillInPanel`.

### Out of Scope

- Syntax highlighting (two-color diff is fine for v1; tree-sitter later).
- Inline comments that steer the agent (Codex-style) — future task.
- Split (side-by-side) view — unified view first.
- Line-number gutter (NSRulerView) — nice-to-have, deferrable.
- Non-git repos / non-Claude agents.

## Constraints

| Type | Constraint | Reason |
|------|------------|--------|
| Technical | No webview; native AppKit rendering only | User directive; keep the stack Swift/libghostty |
| Technical | Diff computed where the repo lives, shipped as data | Remote tmux/tailscale sessions; board never mounts remote FS |
| Technical | Reuse existing hook channel + receiver | task-04 already delivers hook events to the board |
| Architectural | Diff panel is read-only chrome, not the interaction surface | Preserve DD-001 watcher-not-spawner; terminal stays real |

## Dependencies

### Prerequisites

- [x] task-04 live detection complete (hook receiver + registry event path exists)
- [x] `HookInstaller` installs `UserPromptSubmit`/`Stop`/`SessionEnd` hooks

### Blockers

- None known.

## Technical Context

Diff pipeline is deliberately git-sourced (the pattern both T3Code and Codex
converged on — git as diff source, "last turn" as the review unit), NOT
terminal-scraped and NOT SDK-driven. The one AppKit trick required is full-width
line-background drawing via an `NSLayoutManager` subclass overriding
`drawBackground`. Word-level highlighting — the thing that makes diffs feel
premium — is stdlib `CollectionDifference`, no dependency. `Differ`/`DifferenceKit`
are for table-view animation, not code diffs — do not use them.

### Affected Components

- `app/Sources/GhostlingApp/HookInstaller.swift` - add turn checkpoint/diff hook commands
- `app/Sources/GhostlingApp/DrillInPanel.swift` - add Changes tab + turn picker
- `app/Sources/GhostlingCore/SessionRegistry.swift` - store per-session turn diffs
- hook receiver (detector) - accept `turn_diff` events
- new: `DiffModel.swift` (parser + model), `DiffTextView.swift` (renderer)

### Integration Points

- Existing hook event channel (local `localhost`, remote over tailnet) — same path.
- BoardTheme for colors/fonts; SessionCard-style custom layer-backed headers.

## Open Questions

- [ ] Checkpoint storage: `git stash create` dangling commit vs. snapshot file —
      confirm untracked-file handling with `git add -N`.
- [ ] Turn-diff payload size cap / truncation policy for very large turns.
- [ ] Where remote hooks POST (reuse the exact task-04 remote endpoint config).

## References

- T3Code (pingdotgg/t3code, MIT) — git-checkpoint diffs, per-turn scoping (reference only)
- OpenAI Codex app review pane — git-state review, turn scoping
- cmux (sibling, GPL) — clean-room UX reference only, no code reuse
- Memory: [[dd-001-embed-libghostty-decision]], [[task-04-live-detection-complete]]
