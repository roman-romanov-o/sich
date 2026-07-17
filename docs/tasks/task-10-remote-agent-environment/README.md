# TASK-10: Remote Agent Environment

**Status:** Planning
**Mode:** Full
**Created:** 2026-07-16

## Overview

Make agent sessions running on a remote machine (reached over ssh via Tailscale)
behave on the board like local ones — moving through columns, raising attention,
and showing turn diffs — by building the remote→local hook telemetry path that
does not exist today. Scoped as **TASK-10a**; a full remote tree browser is
deferred to 10b.

## Planning Progress

| Step | Status | Artifacts |
|------|--------|-----------|
| Research | Complete | research/*.md |
| Task Description | Complete | task-description.md |
| User Stories | Complete | user-stories/US-001..009 |
| Design Decisions | Complete (in review) | design-decisions/DD-001..004 |
| Code Changes | Complete (3 review rounds; 4 🔴 fixed) | code-changes/*.md (4 contracts) |
| Test Specs | Complete (2 review rounds; 2 🔴 + 7 🟡 fixed) | test-specs/**/*.md (9 specs, 50 cases, coverage-matrix.md) |
| Implementation Plan | Pending | implementation-plan/phase-*.md |

## Next Steps

- [x] Run `/saha:research` to explore the codebase
- [x] Run `/saha:task` to create task description
- [x] Run `/saha:decide` — all three blockers resolved, plus a fourth decision the
      first review round found unowned (all Proposed, pending re-review):
      **DD-001 transport** (in-memory `ssh tail -F` relay; host stamped at
      ingestion; down trigger = ssh exit or ~45s keepalive → distinct `unreachable`;
      `N` retired, `X` = ≤5s), **DD-002 identity** (`GHOSTLING_CARD_ID` on the pane's
      launch command **and** in the tmux session env via `set-environment`, so later
      panes bind too, + card-unique session names), **DD-003 location** (persist the
      remote *spec*, **not** the argv; **no** `PaneSnapshot` version bump; rebuild via
      `RemoteTmuxCommand.argv(for:)`; host-qualified recents), **DD-004 firewall**
      (ssh argvs may only be generated from constrained specs — hard prerequisite for
      DD-003's restore, and it ships first)
- [x] Run `/saha:stories` — US-001..009
- [x] Run `/saha:contracts` — four contracts (the wire is JSONL over `ssh tail -F`, not
      HTTP; there is no REST surface and that is structural). Three questions were closed by
      **reading source rather than trusting field names**, and all three had shipped a wrong
      assumption first: the dedup key differs by line kind and `iteration` does **not**
      identify a diff; `staleVersion` had **no** comparand on disk (now a content hash); and
      the regression example an AC was to be written from was **impossible to make red**
      (`done` is sticky — the real hole is a replay extinguishing `waitingForInput`).
      A fourth 🔴 came from a claim rather than a contract: the README asserted a
      citation sweep that stopped at the `code-changes/` boundary, leaving five wrong
      `BoardShell.swift` line numbers in the DDs it linked to. **A claim of
      thoroughness is itself a citation and decays the same way** — `BoardShell.swift`
      is uncommitted and its `boundCardID` predicate moved four times during planning
      (`1471 → 1482 → 1485 → 1528`), the last hop *during* the session that had just
      grep-verified it. That file is now cited by symbol only.
- [ ] **Confirm two choices made *for* you at `/saha:contracts`**, both flagged in the
      contracts and neither yours: the **host chip on `SessionCard`** as the surface for
      install state (a hosts panel is the plausible alternative), and **accepting bracketed
      IPv6** in the destination grammar (Tailscale hands out IPv6, so refusing it refuses
      real hosts). Overrule at `/saha:plan`, not at implementation time.
- [x] Run `/saha:test-specs` — 9 specs, 50 cases. Round 2 caught a 🔴 **I introduced while fixing a round-1 note**: TC-UNIT-001 was flipped to "green on arrival," which is false against `PoolFirewall.classify` and contradicted the same file 15 lines above. The round-1 note called "Red first. Passes today." self-contradictory; it was not — "passes" meant the *input* passes the firewall (the hole), not the test. **Ambiguity resolved by inverting a claim instead of rewording it.**
- [ ] Run `/saha:plan` — DD-003 chose the narrow option, so the **L**-sized
      host-aware `projectDir` refactor is **out**; sizing shifts to DD-001's
      per-host transport supervision
