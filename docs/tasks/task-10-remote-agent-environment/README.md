# TASK-10: Remote Agent Environment

**Format:** saha/v2 · **Status:** executing (Phase 01 done, Phase 02 next) · **Created:** 2026-07-16

Make agent sessions running on a remote machine (reached over ssh via Tailscale) behave on
the board like local ones — moving through columns, raising attention, showing turn diffs —
by building the remote→local hook telemetry path that does not exist today. Scoped as
**TASK-10a**; a full remote tree browser is deferred to 10b.

- **Spec:** `model/*.c4` — frozen. Open in sich (Planning Mode `◫`) or `likec4 validate model`.
- **Tracking:** `progress.yaml` — the only mutable file; written by the execution loop.
- **Legacy:** `task-description.md`, `user-stories/`, `design-decisions/`, `code-changes/`,
  `test-specs/`, `implementation-plan/` are the pre-migration prose. Frozen reference only —
  not read by tooling, and every line number they cite predates the Ghostling→Sich rename.
