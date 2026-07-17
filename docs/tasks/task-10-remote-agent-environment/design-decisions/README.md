# Design Decisions

Architectural decisions and their rationale.

## Contents

| ID | Title | Status | Date |
|----|-------|--------|------|
| DD-001 | [Remote Hook Telemetry Transport](DD-001-remote-hook-telemetry-transport.md) | Proposed | 2026-07-17 |
| DD-002 | [Remote Card Identity Binding](DD-002-remote-card-identity-binding.md) | Proposed | 2026-07-17 |
| DD-003 | [Location Model and Remote Restore](DD-003-location-model-and-remote-restore.md) | Proposed | 2026-07-17 |
| DD-004 | [PoolFirewall — Inspecting the Command Behind `ssh`](DD-004-poolfirewall-ssh-command-inspection.md) | Proposed | 2026-07-17 |

## Decision Log

### Accepted
_None yet — all four are Proposed pending review._

### Proposed
- **DD-001: Remote Hook Telemetry Transport** — Per-host `ssh … tail -F` relay that
  stamps `ghostling_host` at ingestion and feeds the normalizer in memory; remote
  lines are **never** written to the local `events.jsonl`. Keeps task-03's
  observe-only sink intact. Down-detection rides ssh child-exit + keepalives; the
  line-silence threshold `N` is **retired**, not assigned.
- **DD-002: Remote Card Identity Binding** — Carry `GHOSTLING_CARD_ID` in the tmux
  pane's launch command (mirroring `BoardSeed.liveTerminal`) **and** write it to the
  tmux *session* environment via `set-environment` at create, so panes the user opens
  later (`Ctrl-b c`) are bound too. Plus card-unique session names with
  `(host, sanitized name)` uniqueness. Zero read-side change, no tmux version floor.
- **DD-003: Location Model and Remote Restore** — Persist the remote **spec**
  (`{host, user?, sessionName, …}`), *not* the argv, with **no** `PaneSnapshot`
  version bump; restore rebuilds the command through the same
  `RemoteTmuxCommand.argv(for:)` constructor the create path uses. Host-qualify the
  recents store. The full `SessionLocation` enum is deferred — honestly, at
  unchanged-or-higher cost, not at a discount.
- **DD-004: PoolFirewall — Inspecting the Command Behind `ssh`** — The guarantee is
  **structural**: ssh argvs may only be *generated* from constrained specs, never
  supplied. Requires constraining the constructor's inputs (validate the resolved
  `target`, reject a leading `-`) — without which the claim is false, because `host`
  is unvalidated free text sitting in ssh's **option** position, where
  `-oProxyCommand=…` executes **locally**. A token scan rides underneath as an
  explicitly best-effort net. Hard prerequisite for DD-003's restore; ships first.

### Deprecated
_None_

## Cross-cutting notes

**These four decisions interlock.** DD-001 supplies `ghostling_host` (host
provenance, capturable only at ingestion); DD-002 supplies `ghostling_card_id`
(the primary card join); DD-003 consumes both for restore and for the host-qualified
directory fallback. Criterion 4 (two hosts never conflated) needs the first three.
DD-004 guards all of them: DD-001 adds two ssh-emitting call sites and DD-003 adds a
third that runs at launch from data on disk, and until DD-004 lands the
task-description's `PoolFirewall` constraint is enforced by code review only.

**DD-003 and DD-004 answer the same question the same way**, in two places: prefer a
structural guarantee (a shape that cannot express the bad state) over a coding one (a
check that looks for it). DD-003 persists a spec so the file format cannot name a
command; DD-004 generates argvs from specs so no caller can supply one. Neither
conclusion survives without the other — DD-003's restore is unguarded without DD-004,
and DD-004's closed set is pointless if the snapshot can hand it arbitrary argv.

**The same error was made twice, and it is the thing to watch for in `/saha:plan`:**
claiming a structural property the code does not have yet. Round 1: DD-003 said the
persisted shape kept the watcher invariant while proposing to persist raw argv.
Round 2: DD-003 *and* DD-004 both said "there is no field in which to put a command"
while `host` sat unvalidated in ssh's option position (`-oProxyCommand=…` executes
locally — a hole reachable from ⌘⇧R in **shipped** code). Both times the reasoning
was fine and the premise was unchecked. **A struct is not a constraint; its
constructor is** — so "the shape can't express it" has to be verified field by field,
not inferred from field names.

**One research claim was revised during this step, after verification:**

*"`tmux new-session -A` on attach inherits the original session's env, so the
`GHOSTLING_CARD_ID` fix is invalid"* — **over-read**. Inherited env is stale only when
a session name is reused by a *different* card. Card-unique names make inheritance
correct. See DD-002.

*(A second "revision" was withdrawn. An earlier draft of DD-001 claimed research had
said "the rotation fork is a cost whichever transport wins" and marked it false —
research said the **opposite** (`research/02-hook-telemetry-transport.md` risk 5:
`tail -F` follows by name and handles rotation), so the rebuttal was aimed at nobody.
The underlying observation survives inside DD-001, but it was never decisive; Finding
1 is. Withdrawn after review, 2026-07-17.)*

**One external fact was pinned rather than assumed:** `new-session -e` requires
tmux ≥ 3.2 (tmux CHANGES, "CHANGES FROM 3.1c TO 3.2"). Ubuntu 20.04 ships 3.0a and
Debian 11 ships 3.1c, so with the user's "both/varies" remote-OS answer that flag is
not a safe foundation — which is why DD-002 chose the launch-command form.
`set-environment`, by contrast, has no meaningful version floor (tmux 1.0), which is
why DD-002 can use it without reintroducing one.

**One lever remains unverified and was deliberately not built on:** `$TMUX` /
`tmux display-message` availability inside a hook subprocess has zero precedent in
this repo and would need a spike. It is DD-002's Option 1, rejected partly on that
basis.
