# US-003: Resume sessions after restart

**Priority:** Should Have
**Status:** Ready
**Persona:** Operator
**Estimated Complexity:** L

## User Story

As an **operator**,
I want **my open terminals restored after I quit/restart the app (or the machine)**,
So that **I don't lose my working context**.

## Acceptance Criteria

1. **Given** open terminals with known cwd + session identity
   **When** the app quits
   **Then** a **versioned snapshot** of the window/pane tree is persisted (`{createdAt, version, windows}` shape).

2. **Given** a valid snapshot at launch
   **When** the app starts
   **Then** the terminals are restored (cwd + session identity) matching the pre-quit layout.

3. **Given** a corrupt or partial current snapshot
   **When** the app starts
   **Then** it falls back to the last-known-good (`-previous`) snapshot rather than starting blank or crashing.

4. **Given** a snapshot describing a pane that had an agent running
   **When** the pane is restored
   **Then** only the shell/pane is re-opened — **no `claude -p` (headless) process is spawned** (the watcher-not-spawner invariant; resuming the agent is the operator's action).

## Edge Cases

1. **Schema version mismatch**
   - Trigger: snapshot written by an older/newer build.
   - Expected: migrate if possible, else ignore that snapshot and start clean — never crash.

2. **cwd no longer exists**
   - Trigger: directory deleted between sessions.
   - Expected: restore the pane pointed at a safe fallback (home), flagged, not hung.

3. **Underlying process already dead**
   - Trigger: the agent process didn't survive.
   - Expected: restore the pane as closed/dead, not as a live-but-frozen terminal.

## Technical Notes

Persist/restore in `PTYSession`/`SessionRegistry`; store under Application Support; write current + `-previous` (rotate on successful load). Watcher-not-spawner: restoring must **not** auto-launch `claude -p` — it re-opens the shell/pane, the agent is the operator's to resume.

## Dependencies

- **Requires:** none (independent of US-001/002).
- **Enables:** a persistent mission-control surface.

## Questions

- [ ] Exact Application Support path for the SwiftPM app bundle.

## Related

- Task: `../task-description.md` (Success Criterion 7)
