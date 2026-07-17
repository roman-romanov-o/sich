# Phase 02: Portable Forwarder & Remote Install

**Status:** Not Started
**Estimated Effort:** L
**Dependencies:** Phase 01 (the install/probe argvs must pass the firewall)

## Objective

Make hooks installable on a remote GNU/Linux host from the app, emitting the same JSONL a
local host emits, and surface each host's install state on its card. **Nothing emits an
event until this phase runs** — it is the source end of the pipe the next phase carries.

## Why before the relay

US-005 (install) must precede US-003 (relay) in the story map: a relay tailing a file that
no forwarder writes to would be green against an empty file forever. US-002 (a *portable*
forwarder) must precede US-005 (installing it), because installing a macOS-only forwarder on
Linux fails at first run, not at review.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-002 Turn diffs survive GNU userland | Must Have | M |
| US-005 Hooks install on a remote host | Must Have | L |

### Out of Scope (Deferred)

- The `ssh tail -F` relay that reads what the forwarder writes — Phase 03.
- The create-palette UI that triggers install — Phase 06. This phase installs from a spec;
  the door that builds the spec comes last.

## Implementation Steps

### Step 1: Make the forwarder script GNU-portable

**Description:** The forwarder rotates at 5 MiB via `mv -f`, base64-encodes diffs, and reads
tool state. Every userland assumption that differs on Linux must be neutralised.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/HookInstaller.swift` — the `forwarderScript` string:
  no `plutil` (absent on Linux); `base64` decode must tolerate GNU's 76-column wrapping;
  `tail -F` (= `--follow=name --retry`) to match the `mv`-based rotation.

**Technical Notes:**
- **BSD vs GNU `base64` wrapping** is the concrete failure: the macOS-authored decode path
  silently corrupts a wrapped payload. TC-E2E-017 (human, real Linux) is the only place the
  real GNU path runs; the automated fixture emulates GNU userland but cannot *be* it.
- The forwarder carries **no version marker** by deliberate decision — `grep -c version
  HookInstaller.swift` counts 1 today, at the unrelated `--version)` arg handler
  (`:328`), not in `forwarderScript`. Do not add one to make probing easier; DD-001 probes
  by content, not version string.

**Acceptance Criteria:**
- [ ] US-002 AC-1: the forwarder script contains no `plutil` and no fixed-width base64
  assumption.
- [ ] US-002 AC-2: **human sign-off** — real diff from a real Linux box renders. Never
  auto-passable; the DoD gate classifies it `needs_human_signoff`.

**Tests:** TC-INT-017 (GNU-userland fixture), **TC-E2E-017 (human)**

---

### Step 2: Install + probe over a PTY-free channel

**Description:** Install the forwarder + hooks on the host and read back a probe state
(`installed` / `staleVersion` / absent) without allocating a PTY.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/HookInstaller.swift` — remote install + probe entry points.
- `app/Sources/GhostlingCore/RemoteHookInstallState.swift` (new, per the
  `remote-host-state.md` contract) — the install-state model.

**Technical Notes:**
- The probe argv must have **no `-t`**: `ssh -t` allocates a PTY that rewrites LF→CRLF and
  shifts every byte after the first newline, so a byte-compared probe reads `staleVersion`
  against a correctly-installed host. `argv(for:)` hardcodes `-t` for the *interactive tmux*
  shape only; the probe is a distinct, PTY-free argv. TC-INT-013 does **not** catch this
  (against a substituted child `-t` is inert) — the coverage is TC-INT-012 (argv carries no
  `-t`) plus TC-E2E-019 (real channel).

**Acceptance Criteria:**
- [ ] US-005 AC-1..3: install writes the forwarder and hook config; probe reads `installed`.
- [ ] US-005 AC-4: install state renders on the card.

**Tests:** TC-INT-012, TC-INT-013, TC-INT-014, TC-INT-015, TC-INT-016, TC-INT-018,
**TC-E2E-019 (human)**

---

### Step 3: The host chip on `SessionCard`

**Description:** Surface install/host state as a chip on the card — the user's confirmed
choice at `/saha:plan` over a separate hosts panel.

**Files to Create/Modify:**
- `app/Sources/GhostlingApp/SessionCard.swift` — a host chip built the **same layer-backed,
  custom-drawn way `repoChip()` is** (SessionCard is the codebase's proven visible-chrome
  path; a stock `NSButton` was the lone outlier that rendered invisibly and is not the model
  here).

**Technical Notes:**
- TC-E2E-016 asserts four states via a **real click / `NSEvent` dispatch** on the chip;
  `cacheDisplay`/`CALayer.render` are non-evidence for a visual AC and must not stand in for
  it.

**Acceptance Criteria:**
- [ ] US-005 AC-4: the chip renders and distinguishes install states on the real render path.

**Tests:** TC-E2E-016

## Definition of Done

- [ ] US-002 (incl. human TC-E2E-017) and US-005 (incl. human TC-E2E-019) satisfied.
- [ ] Human sign-off rows recorded in `real-linux-host-signoff.md`; an empty log fails the
  gate.
- [ ] `swift test` count strictly increases; `swift build` warning-clean.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| GNU/BSD userland drift ships green because CI is BSD-only | High | High | US-002 AC-2 and US-005 are `needs_human_signoff`; the automated fixture is honest that it emulates, not reproduces, GNU userland. |
| The `-t` PTY bug ships green because TC-INT-013 can't see it | Medium | High | Coverage is explicitly reassigned to TC-INT-012 (argv shape) + TC-E2E-019 (real channel), documented in the integration spec. |
| Host chip renders invisibly (the bug that bit 4× on stock controls) | Medium | Medium | Build it the `repoChip()` layer-backed way; TC-E2E-016 dispatches a real event, not a cached render. |

## Notes

Host chip surface confirmed by the user at `/saha:plan` (was my proposal, not theirs).

## Related

- **Stories:** US-002, US-005
- **Decisions:** DD-001 (forwarder/rotation), DD-002 (install carries identity)
- **Contracts:** [remote-hook-event-channel.md](../code-changes/remote-hook-event-channel.md),
  [remote-host-state.md](../code-changes/remote-host-state.md)
- **Tests:** [integration/remote-hook-install-and-probe.md](../test-specs/integration/remote-hook-install-and-probe.md),
  [e2e/real-linux-host-signoff.md](../test-specs/e2e/real-linux-host-signoff.md)
