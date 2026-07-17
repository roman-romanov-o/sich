# US-004: State Lands on the Right Card

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator (the developer running agents on the board)
**Estimated Complexity:** L

## User Story

As an **operator**,
I want to **my remote session's running → waiting → done transitions to move the card I started it from, and only that card, even when I have sessions on two different hosts**,
So that **the board tells me the truth about which agent needs me — which is the entire point of watching them**.

## Acceptance Criteria

- [ ] **AC-1:** A card started against a remote host moves running → waiting → done as the remote session progresses, driven by relayed hooks. The join is by `GHOSTLING_CARD_ID`, matched against `card.id.uuidString` in `BoardShell.applySessions` (`observed.filter { $0.boundCardID == card.id.uuidString }`, in `BoardShell.applySessions`) — zero read-side change.
- [ ] **AC-2:** **A pane the user opens later inside the same tmux session (`Ctrl-b c`) is also bound.** This is the load-bearing half: a launch command sets one shell's *process* env, not the tmux *session* env, so binding only the launch command leaves the second pane unbound — the card silently reads "not observed" while the terminal works fine. Test the **second** pane; testing the launch argv alone ships this green and broken.
- [ ] **AC-3:** Two hosts are never conflated: sessions and diffs from host A and host B, and from local, remain distinct even when their `cwd` strings are byte-identical. Uses `ghostling_host` from US-003 AC-2.
- [ ] **AC-4:** Two cards cannot silently become one tmux session: `(host, sanitized session name)` is unique across cards. Today the name field is free text, `sanitizeSessionName` is lossy, and blank defaults to `"ghostling"` — so two cards named `ghostling` on one host genuinely *are* one session, because `-A` attaches.
_(An earlier AC-5 — "'not observed' is never shown bare" — **moved to US-005**, where the install-state machine that owns the message lives. It was install-state messaging leaking into the identity story.)_

## Edge Cases

1. **`tmux new-session -A` attaches instead of creating**
   - Trigger: re-opening a card whose session already runs.
   - Expected behavior: correct. On attach, tmux inherits the **original** session's env and ignores the command argument — which is right, because the original session belongs to this same card. Inherited env is stale **only** when a session name is reused by a *different* card, which AC-4 makes impossible. (This revises research's "highest-value finding," which read the inheritance as fatal; it is not, given card-unique names.)

2. **A card is deleted and a new one reuses the name**
   - Trigger: name collision across the lifetime of a host.
   - Expected behavior: AC-4's uniqueness is over live cards; a recreated card with a stale remote session of the same name inherits the **old** card's ID. Needs an explicit answer — see Questions.

3. **A session the operator started by hand in the same tmux server**
   - Trigger: no `GHOSTLING_CARD_ID` in its env, under a name no card uses.
   - Expected behavior: falls back to the host-qualified directory join, or reads "not started by ghostling" — never binds to an unrelated card.

4. **A hand-created session already occupies the card's own name**
   - Trigger: the operator ran `tmux new -s ghostling` on the host themselves, before ever creating the card. AC-4's uniqueness is scoped *across cards* and does not cover a collision with a session ghostling did not create.
   - Expected behavior: must not bind silently to nothing. `-A` **attaches and ignores the command argument**, so `set-environment` never runs, the pane has no `GHOSTLING_CARD_ID`, and the card reads "not observed" while the terminal works perfectly — the exact silent-failure shape this story exists to prevent. Probe whether the session pre-exists without the ID and either run `set-environment` **post-attach** or surface the collision. Note this makes the `-A` inheritance argument (edge case 1) conditional on ghostling having created the session, which is true for *cards* but not for the host.

## Technical Notes

Mechanism (DD-002):
`tmux new-session -A -s <name> 'tmux set-environment GHOSTLING_CARD_ID <uuid>; GHOSTLING_CARD_ID=<uuid> exec $SHELL -il'`

Both halves are required, and the `set-environment` half is the one that was missing from the first draft. `set-environment` has no meaningful version floor (tmux 1.0), so it costs none of the version-independence this decision is built on.

`new-session -e` — the clean syntax — needs **tmux ≥ 3.2** (verified in tmux CHANGES, "CHANGES FROM 3.1c TO 3.2"). Ubuntu 20.04 ships 3.0a and Debian 11 ships 3.1c, so under "remote OS: both/varies" it is not a safe foundation. That is why the launch-command form wins.

Rejected: deriving the ID at hook time from `$TMUX` / `tmux display-message` (**unverified** in this repo, needs a spike); `ssh SendEnv` (needs remote `AcceptEnv` and is **silently dropped** without it — the same silent-failure class as `board-status-bug-was-missing-global-hooks`).

This command nests four quoting levels (`ssh → sh → tmux → sh`). US-001 AC-5 must assert its **final** shape.

## Dependencies

- **Requires:** US-003 (events must arrive before they can be bound), US-001 (this argv is generated, not composed).
- **Enables:** US-006 (a restored card must rebind), US-002 AC-2 (drill-in diffs need the card join).

## Execution History

| Iteration | Phase | Result | Notes |
|-----------|-------|--------|-------|
| - | - | - | Not yet executed |

## Questions

- [ ] When a card is deleted while its remote tmux session survives, and a new card later takes the same `(host, name)`, it attaches to a session carrying the **dead** card's ID. Reap on delete, or refuse the name while the remote session lives?
- [x] ~~Which surface shows "hooks not installed on `<host>`"?~~ **Resolved at `/saha:contracts`:** a host chip on `SessionCard`, built on the same layer-backed render path as `repoChip()` (`SessionCard.swift:100`, :250-261). Owned by US-005; specified in [code-changes/remote-host-state.md](../code-changes/remote-host-state.md).

## Related

- Task: [task-description.md](../task-description.md) — success criteria 1, 4
- Design Decision: [DD-002](../design-decisions/DD-002-remote-card-identity-binding.md), [DD-001](../design-decisions/DD-001-remote-hook-telemetry-transport.md) (supplies `ghostling_host`)
