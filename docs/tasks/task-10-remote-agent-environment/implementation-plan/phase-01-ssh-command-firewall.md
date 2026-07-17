# Phase 01: ssh Command Firewall

**Status:** Not Started
**Estimated Effort:** M
**Dependencies:** none — this is the foundation the rest of the task builds on

## Objective

Make it structurally impossible to generate an ssh argv that smuggles headless
`claude -p` work, and close the live `-oProxyCommand=` hole reachable from ⌘⇧R in shipped
code today. Nothing downstream may emit an ssh command until this lands.

## Why this is Phase 01, not a hardening pass at the end

DD-004 is a **hard prerequisite** for DD-001's relay (Phase 03) and DD-003's restore
(Phase 05): both add ssh-emitting call sites, and DD-003's runs at launch from data on
disk with no human present. Until this phase ships, the task-description's `PoolFirewall`
constraint is enforced by code review only. Building it last would mean every intermediate
phase ships an unguarded ssh emitter.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-001 ssh Commands Cannot Smuggle Headless Work | Must Have | M |

### Out of Scope (Deferred)

- The relay that *uses* `RemoteTmuxCommand.argv(for:)` — Phase 03.
- The restore call site — Phase 05.
- The create-palette destination input — Phase 06. (This phase constrains the *grammar*;
  the UI that feeds it comes later.)

## Implementation Steps

### Step 1: Constrain the constructor's inputs

**Description:** The guarantee lives in the shape of what `argv(for:)` will accept, not in a
downstream check. **A struct is not a constraint; its constructor is** — so validate the
*resolved, trimmed destination string that is actually appended*, field by field, not the
struct's field names.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/RemoteTmuxCommand.swift` — validate the composed `target`
  (reject a leading `-` **post-trim**, on the exact token appended); accept bracketed IPv6
  (`[fe80::1]`, `[fe80::1]:22`) as a valid destination. `parse()` **keeps its Optional
  return** and does not become throwing — a spec built directly never passes through it, so
  the guard cannot live in `parse`.

**Technical Notes:**
- The dangerous position is ssh's **option** position, not the remote-command position:
  `-oProxyCommand=…` executes **locally** and never crosses the network. The composed
  destination (`\(user)@\(host)`) sits there, so both `user` and `host` are unguarded free
  text — guard the *composed* destination, not `host` alone.
- The `target` property composes the **untrimmed** host while the appended token is
  **trimmed**; a guard on `spec.target` passes a leading-whitespace payload that ssh then
  receives trimmed. Validate the trimmed token.

**Acceptance Criteria:**
- [ ] AC-2/AC-3/AC-4: a destination resolving to `-oProxyCommand=…` throws
  `invalidDestination`, whether via `parse()`, via the user position, or built directly with
  leading whitespace.
- [ ] AC-5: the relay, install, probe, and final tmux argvs all still classify clean; the
  bracketed-IPv6 destination passes.

**Tests:** TC-UNIT-002, TC-UNIT-003, TC-UNIT-004, TC-UNIT-005, TC-UNIT-007

---

### Step 2: Teach `PoolFirewall` to look behind `ssh`

**Description:** A best-effort token scan riding *underneath* the structural guarantee, not
in place of it. `classify` gates `assertNoHeadlessFlag` behind `isClaude(argv.first)`, and
`isClaude("/usr/bin/ssh")` is false — so an ssh remote command is waved through uninspected
today.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/PoolFirewall.swift` — when `argv.first` is ssh, scan the
  remote-command token for headless `claude` invocation.

**Technical Notes:**
- This is explicitly the *net*, not the *floor*. The floor is Step 1: argvs are only ever
  *generated* from constrained specs, never supplied. The scan catches a headless command
  that somehow reaches the firewall anyway.

**Acceptance Criteria:**
- [ ] AC-1: `classify(["/usr/bin/ssh", "host", "claude -p 'x'"])` throws. **Red today** —
  it returns `.interactive` uninspected. Prove red before green.

**Tests:** TC-UNIT-001 (red-first), TC-UNIT-006 (quoting asserted against `remoteQuoted`,
reached through `argv(for:)` output — it is `private static`)

---

### Step 3: Route every generated argv through the chokepoint

**Description:** The three ssh-emitting call sites this task adds must all pass their argv
through `PoolFirewall.classify`. This phase wires the seam and the test; Phases 03/05
attach the actual call sites.

**Files to Create/Modify:**
- `app/Tests/GhostlingCoreTests/RemoteTmuxCommandTests.swift`, `PoolFirewallTests.swift`
  (both exist) — add the cases below.

**Tests:** TC-INT-018 (install/probe argvs pass the firewall, generated from a constrained
spec, never composed from free text)

## Definition of Done

- [ ] US-001 all six ACs green; AC-1/AC-2 proven **red before green**.
- [ ] `swift test` count strictly increases (no test deleted to make the suite pass — the
  dual-baseline integrity check the DoD gate enforces).
- [ ] `swift build` warning-clean; new functions ≲50 lines, single-responsibility.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| A "structural" claim the code doesn't yet have (the 🔴 that landed twice in `/saha:decide`) | Medium | High | Every "the shape can't express this" AC is verified field-by-field on the *trimmed appended token*, and TC-UNIT-004 exists precisely to distinguish the correct guard from the plausible-wrong one — both produce a running ssh. |
| Legitimate destinations refused (bracketed IPv6, `user@host:port`) | Low | Medium | TC-UNIT-005's table pins the accepted grammar; IPv6 acceptance is now the user's confirmed decision. |

## Notes

Bracketed IPv6 acceptance was confirmed by the user at `/saha:plan` (Tailscale hands out
IPv6). It is no longer a flagged proposal.

## Related

- **Stories:** US-001
- **Decisions:** DD-004
- **Contracts:** [remote-tmux-command.md](../code-changes/remote-tmux-command.md)
- **Tests:** [unit/ssh-argv-and-firewall.md](../test-specs/unit/ssh-argv-and-firewall.md)
