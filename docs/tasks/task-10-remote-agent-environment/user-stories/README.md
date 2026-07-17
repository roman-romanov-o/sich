# User Stories

User stories define features from the user's perspective.

## Contents

| ID | Title | Priority | Status |
|----|-------|----------|--------|
| US-001 | [ssh Commands Cannot Smuggle Headless Work](US-001-ssh-commands-cannot-smuggle-headless-work.md) | Must Have | Draft |
| US-002 | [Turn Diffs From a Linux Host](US-002-turn-diffs-from-a-linux-host.md) | Must Have | Draft |
| US-003 | [Remote Hook Events Reach the Laptop](US-003-remote-hook-events-reach-the-laptop.md) | Must Have | Draft |
| US-004 | [State Lands on the Right Card](US-004-state-lands-on-the-right-card.md) | Must Have | Draft |
| US-005 | [Install Hooks on a Remote Host](US-005-install-hooks-on-a-remote-host.md) | Must Have | Draft |
| US-006 | [A Remote Card Survives Restart](US-006-a-remote-card-survives-restart.md) | Must Have | Draft |
| US-007 | [A Dead Connection Looks Dead](US-007-a-dead-connection-looks-dead.md) | Must Have | Draft |
| US-008 | [Reconnect Does Not Duplicate History](US-008-reconnect-does-not-duplicate-history.md) | Must Have | Draft |
| US-009 | [Choose a Remote Host and Folder at Card Creation](US-009-choose-a-remote-host-and-folder-at-card-creation.md) | Must Have | Draft |

All nine are Must Have. That is not priority inflation — the task was already
scoped down (remote quota, remote worktrees, a remote tree browser and a remote
helper binary were all cut before stories were written), and what survives is the
minimum that makes a remote session a *card* rather than a terminal. Priority does
not order the work here; **dependencies do**, and the story map below is the real
sequence.

## Story Map

### Foundation — ships first, before the call sites exist
- **US-001: ssh Commands Cannot Smuggle Headless Work** — closes a hole that is live
  in shipped code today, and constrains the three ssh-emitting call sites the rest
  of this task adds.

### The pipe — a remote session becomes observable
- **US-002: Turn Diffs From a Linux Host** — makes the forwarder portable. Must
  precede US-005, or US-005 installs a forwarder that moves cards and silently drops
  diffs.
- **US-005: Install Hooks on a Remote Host** — nothing emits events until this runs.
- **US-003: Remote Hook Events Reach the Laptop** — the `ssh … tail -F` relay.

### The join — events become *this card's* events
- **US-004: State Lands on the Right Card** — identity binding plus host namespacing.
  This is where the task's headline outcome (running → waiting → done, remotely)
  first exists.

### The guards — the board tells the truth when things go wrong
- **US-007: A Dead Connection Looks Dead**
- **US-008: Reconnect Does Not Duplicate History**
- **US-006: A Remote Card Survives Restart**

### The door — the operator's actual ask
- **US-009: Choose a Remote Host and Folder at Card Creation** — last, deliberately.
  ⌘⇧R is this task's own demo path; retiring it early would make unfinished palette
  UI a prerequisite for demonstrating everything above it.

### Persona

There is effectively **one** persona — the operator running agents on the board —
because this is single-operator tooling. US-005 addresses them in a distinct
moment (setting up a new box for the first time) rather than as a distinct person,
and that framing is what surfaced its explicit/implicit-install question.

## Coverage of the frozen success criteria

Every criterion in [task-description.md](../task-description.md) has a story, and
every story traces to a criterion or to a named constraint:

| Criterion | Story |
|-----------|-------|
| 1. Remote state reaches the correct card | US-003 + US-004 |
| 2. Turn diffs under GNU/Linux userland | US-002 (both ACs, one story) |
| 3. Probe-derived per-host install state | US-005 |
| 4. Two hosts never conflated | US-004 (AC-3) |
| 5. Remote card survives restart | US-006 |
| 6. Transport-down visible, never counterfeits liveness | US-007 |
| 7. Reconnect replay produces no duplicates | US-008 |
| 8. Remote first-class at card creation, per-host recents | US-009 |
| 9. No inbound listener, no new remote binary | US-003 (AC-4), US-005 (AC-5) |
| *Constraint:* watcher-not-spawner across ssh | US-001 |

Criterion 9 is an **invariant, not a feature** — there is no story to demonstrate
"nothing was added." It is carried as a structural assertion inside the two stories
that could violate it, which is where it can actually be tested.

## Two things worth carrying into `/saha:plan`

**A struct is not a constraint; its constructor is.** The same mistake landed a 🔴
twice during `/saha:decide`: claiming a structural property the code does not have.
US-001 AC-4 and US-006 edge case 3 exist because of it. When a story says "the shape
cannot express that," verify it **field by field** — never infer it from field names.

**The green-but-broken traps this repo has already hit** are written into ACs
rather than left to reviewer memory: interaction ACs must dispatch a **real event**
(US-004 AC-2, US-005 AC-4, US-009 AC-4); negative assertions carry the weight where
a positive one would pass while the UI still lies (US-007 AC-3); and a bug fix is
**proven red before green** (US-001 AC-1/AC-2, US-002 AC-1, US-006 AC-1).
