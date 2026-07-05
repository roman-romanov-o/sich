# US-001: Single-binary launch (no Python sidecar)

**Status:** Draft
**Priority:** Critical
**Persona:** Operator / Installer
**Estimated Complexity:** M
**Last Updated:** 2026-06-26

## User Story

As an **operator running Ghostling**,
I want the app to run as a **single Swift binary with no Python process and no localhost server**,
So that **install and launch are one app — nothing to `pip install`, no `.venv`, no port to collide on**.

## Description

Today launching the app spawns a Python sidecar (`SidecarProcess`) and talks to it over
`127.0.0.1:8787`. This story is the end-state: the app boots, the board and quota panel fill
with live data, and **no Python is involved**. It is the *observable* outcome of US-002 (native
quota) + US-003 (native hooks) + US-004 (delete the core); the ACs here assert the absence of
the sidecar, the others assert the replacements work.

## Acceptance Criteria

- [ ] **AC1 — no child process:** Launching `ghostling` spawns **zero** `python`/`python3`
  child processes (assert by inspecting the app's child PIDs / process tree).
- [ ] **AC2 — no listener:** After launch, **nothing** is bound on `127.0.0.1:8787` (the port is
  free; `SidecarProcess` and `HookEndpoint` no longer exist).
- [ ] **AC3 — data still live:** With no sidecar, the quota panel shows the interactive pool
  populated and the board shows reconciled sessions (the replacements from US-002/US-003 carry
  the load).

## Edge Cases

1. **A stale sidecar is already on the port** (left by an old build)
   - Trigger: a previous `8787` listener is still running when the new app launches.
   - Expected: the new app **ignores it entirely** — it neither spawns one nor depends on one.
     (Today's `isHealthy()` "reuse the port" dance is deleted, not preserved.)

2. **Repo / `~/.claude` not found**
   - Trigger: app launched outside a repo, or no Claude transcripts yet.
   - Expected: app still launches; quota interactive pool reads as **empty/fresh** (not a crash,
     not `unknown` — there is genuinely no usage), per US-002 AC3.

## Dependencies

- **Requires:** US-002 (native quota reads), US-003 (native hook sink), US-004 (delete core).
- **Related:** task-01 DD-001 (the pool firewall / watcher discipline this preserves).

## Related Decisions

- DD-001 (eliminate the sidecar), DD-002 (no in-app server).

## Notes

This is the cmux parity point: a single macOS app, no companion daemon. The watcher-not-spawner
constraint is **unchanged** — removing the sidecar removes a *localhost HTTP server*, not any
spawn capability (there never was one).
