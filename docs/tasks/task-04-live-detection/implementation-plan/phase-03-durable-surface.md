# Phase 03: Durable & rich surface

**Status:** Complete (iteration 3)
**Estimated Effort:** L
**Dependencies:** none (independent of Phase 01/02; deferrable)

## Objective

Make the surface durable (restart resume) and its signal richer (semantic shell
integration). These are the Should/Could-have ports; they don't touch the
stated pain but round out the mission-control surface.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-003 | Should Have | L |
| US-004 | Could Have | M |

## Implementation Steps

### Step 1: Versioned session-tree snapshot + `-previous` fallback (US-003)

**Description:** Persist a `{createdAt, version, windows}` window/pane snapshot on
quit; restore on launch; fall back to `-previous` on corrupt/partial.

**Files:**
- `app/Sources/GhostlingCore/SessionRegistry.swift` / `PTYSession.swift` — serialize the pane tree (cwd + session identity) under Application Support; write current, rotate prior to `-previous` on successful load.

**Technical Notes:**
- **Watcher invariant:** restore re-opens the shell/pane only — it must **not** auto-launch `claude -p`; resuming the agent is the operator's action.
- Version mismatch → migrate or ignore-that-snapshot, never crash.
- cwd gone → fall back to home, flagged. Process dead → restore pane as closed, not live-frozen.

**Acceptance Criteria:**
- [x] Quit writes a versioned snapshot; launch restores the pre-quit layout.
- [x] Corrupt current snapshot → `-previous` used; no blank/crash.
- [x] Restore never spawns `claude -p`.

**Tests:** TC-INT-020, TC-UNIT-021, TC-UNIT-022

---

### Step 2: Ghostty shell-integration install (US-004)

**Description:** Install `ghostty-integration.zsh` + `xterm-ghostty` terminfo
idempotently (mirroring the hook installer) so cwd/command boundaries are
reported semantically.

**Files:**
- `app/Sources/GhostlingApp/HookInstaller.swift` (+ a sibling installer) and `.claude/scripts/enable-board-hooks.sh` pattern — bundle + install the integration; preserve the user's rc.

**Technical Notes:**
- Non-zsh shells degrade gracefully (skip or install the matching integration) — never break the shell.
- Sharpens US-002's dir/cwd key but is not required by it (the `updatedAt` ordering stands alone) → Could-have.

**Acceptance Criteria:**
- [x] cwd is reported semantically (not process-scan inferred).
- [x] Install is idempotent; second launch is a no-op; rc preserved.

**Tests:** TC-INT-023, TC-UNIT-024

## Definition of Done

- [x] US-003 + US-004 ACs bound to named green tests.
- [x] `swift test` green; restore proven to not spawn `claude -p`.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Snapshot restore spawns an agent | Low | High (invariant breach) | explicit TC-UNIT-022 asserts no `claude -p` |
| Application Support path unknown for SwiftPM bundle | Med | Low | resolve once, record in US-003 open question |
| Shell rc corruption on install | Low | High | idempotent marker block; TC-INT-023 preserves rc |

## Notes

Fully deferrable behind Phase 01+02 — ship the pain fix first, then durability. US-003/US-004 logic wired into BoardShell's lifecycle (persistOnTerminate, restoreOnLaunch, installShellIntegration) and live PTY read loop (PTYSession.ingest → OSC7CwdReader) in iteration 4, resolving earlier dead-code gap.

## Related

- **Stories:** US-003, US-004
- **Decisions:** DD-001 (watcher posture on restore)
- **Tests:** TC-INT-020, TC-INT-023, TC-UNIT-021, TC-UNIT-022, TC-UNIT-024
