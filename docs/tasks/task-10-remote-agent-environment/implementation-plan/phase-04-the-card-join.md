# Phase 04: The Card Join

**Status:** Not Started
**Estimated Effort:** L
**Dependencies:** Phase 03 (lines arrive, host-stamped), Phase 02 (identity is installed
onto the pane), Phase 01 (the tmux argv passes the firewall)

## Objective

Bind each relayed, host-stamped line to the *correct* card, so a remote agent moves its card
running → waiting → done exactly as a local one does. **This is where the task's headline
outcome first exists.** This is DD-002.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-004 Remote state lands on the right card | Must Have | L |

### Out of Scope (Deferred)

- Surviving a restart — Phase 05 (needs the persisted spec).
- Dead-connection `unreachable` and reconnect dedup — Phase 05.

## Implementation Steps

### Step 1: Stamp the card identity onto the pane

**Description:** `GHOSTLING_CARD_ID` must ride the tmux pane's launch command **and** be set
in the tmux session environment, so panes the user opens later (`Ctrl-b c`) bind too.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/RemoteTmuxCommand.swift` — `argv(for:)` emits the card id on the
  launch command and issues `set-environment` for the session; **card-unique session names**.

**Technical Notes:**
- **`set-environment`, not `new-session -e`.** `-e` needs tmux ≥3.2; Ubuntu 20.04 ships
  3.0a and Debian 11 ships 3.1c, so `-e` fails silently there. `set-environment` has existed
  since tmux 1.0 — no version floor. This is DD-002's explicit choice and the reason there is
  no tmux version gate in the code.
- **`new-session -A` on ATTACH inherits the original session's env** — stale only when a
  *different* card reuses a session name. Card-unique names close that; the staleness is a
  card-modeling bug, not an identity one.
- The pane binds by **pty identity** (`ptyByCard`), not by `card.sessionID` (which is a
  title slug, not the registry UUID) — the join is pty-based, matching the existing local
  join.

**Acceptance Criteria:**
- [ ] US-004 AC-1: a remote agent's first turn moves its card, and only its card.
- [ ] US-004 AC-2: a **second pane opened by hand** in the same session also binds — the
  load-bearing half.

**Tests:** TC-E2E-001, TC-E2E-003, TC-INT-007, TC-INT-008, TC-INT-009, TC-INT-010,
TC-INT-011, **TC-E2E-018 (human, real tmux)**

**Tooling:** TC-INT-007..011 require `brew install tmux` (absent today) and must **skip
loudly** when tmux is missing — a skipped test reporting green is the exact failure this task
documents.

---

### Step 2: Namespace state by host

**Description:** Two hosts can run sessions with colliding local identifiers; the card key
must be `(host, …)` so host A's activity never moves host B's card.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/SessionRegistry.swift` — host-qualified session keys, fed by the
  `ghostling_host` stamp from Phase 03.

**Technical Notes:**
- The earlier "shared-repo dir moves BOTH cards" bug is the local analogue; host-namespacing
  is the remote generalisation of the identity-binding fix.

**Acceptance Criteria:**
- [ ] US-004 AC-3: identically-named sessions on two hosts move only their own cards.

**Tests:** TC-INT-009, TC-INT-010 (host-namespacing cases)

## Definition of Done

- [ ] US-004 all ACs green; AC-2 confirmed on real tmux (human TC-E2E-018).
- [ ] tmux-dependent tests skip loudly, never silently green, when tmux is absent.
- [ ] `swift test` count strictly increases; `swift build` warning-clean.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `set-environment` vs `-e` chosen wrong → later panes unbound on old tmux | Medium | High | DD-002 fixes `set-environment`; TC-INT/TC-E2E-018 exercise a hand-created second pane. |
| tmux-absent CI reports the join green by skipping | High | High | Tests skip **loudly**; coverage-matrix flags `brew install tmux` as the one new tool dep. |
| Host-namespacing missed → cross-host card bleed | Medium | High | AC-3 tests two hosts with colliding names. |

## Notes

Identity binding is the trickiest work in the task; it is isolated in its own phase so its
risk does not entangle the relay (Phase 03) or the guards (Phase 05).

## Related

- **Stories:** US-004
- **Decisions:** DD-002
- **Contracts:** [remote-tmux-command.md](../code-changes/remote-tmux-command.md)
- **Tests:** [integration/tmux-env-binding.md](../test-specs/integration/tmux-env-binding.md),
  [e2e/remote-session-lands-on-its-card.md](../test-specs/e2e/remote-session-lands-on-its-card.md)
