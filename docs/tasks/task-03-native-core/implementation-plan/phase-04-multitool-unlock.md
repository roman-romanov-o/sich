# Phase 04: Multi-tool unlock (stretch)

**Status:** Pending (stretch — not on the cutover critical path)
**Estimated Effort:** M
**Last Updated:** 2026-06-26

## Objective

Light up the board for non-Claude agents (Cursor, Codex, Gemini) by installing per-agent hooks that
append to the **same** event file and teaching the normalizer their event names. The file sink (DD-002)
makes this config + a map, not a new transport.

## Prerequisites

- Phase 03 done (single binary, file sink is the one transport).
- Rosetta-Stone table: [[cmux-detection-is-hooks-not-terminal-scraping]] +
  `CMUXCLI+AgentHookDefinitions.swift` (clean-room the interface facts, not the GPL code).

## Steps

### Step 1: Per-agent installers
- [ ] Cursor → `~/.cursor/hooks.json` (flat); events `stop`/`afterAgentResponse` (done),
      `beforeShellExecution` (waiting).
- [ ] Codex → `~/.codex/hooks.json` (nested) + `hooks=true` in `config.toml`; `Stop` (done).
- [ ] Gemini → `~/.gemini/settings.json` (nested); `AfterAgent`/`SessionEnd` (done).
- [ ] Each installer is a no-op-with-message if the agent's config dir is absent (don't create
      empty configs). Snippet sets `provider` so sessions are labeled.

**Files:** `.claude/scripts/enable-<agent>-hooks.sh` (mirror `enable-board-hooks.sh`).

### Step 2: Extend the normalizer
- [ ] Map each agent's event names into the existing `SignalKind`s; unknown → `UNKNOWN`.
- [ ] Carry the `provider` field through to the session so the board/quota can distinguish it.

**Files:** `app/Sources/GhostlingCore/HookNormalizer.swift` (per-provider maps).

## Acceptance Criteria

- [ ] A Cursor `stop` line lights the board identically to a Claude `Stop`. **TC-INT-340.**
- [ ] Sessions carry their provider; an unknown event → `UNKNOWN` (no false done/waiting). **TC-INT-341.**

## Definition of Done

- [ ] At least Cursor end-to-end (installer → append → board) green; normalizer per-provider maps
      tested. The "unlock my colleagues" demo works.

## Related
- **Stories:** US-005. **Decisions:** DD-002.
