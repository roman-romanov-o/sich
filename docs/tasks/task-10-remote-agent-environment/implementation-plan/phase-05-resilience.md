# Phase 05: Resilience — Dead Connections, Replay, Restart

**Status:** Not Started
**Estimated Effort:** L
**Dependencies:** Phase 04 (a live, correctly-bound remote card to protect), Phase 01 (the
restore call site's argv passes the firewall)

## Objective

Make the board tell the truth when the remote channel misbehaves: a dead connection reads
`unreachable` (not a frozen `running`), a reconnect never duplicates or rewinds a card, and a
remote card survives an app restart. This phase covers US-007, US-008, and DD-003's restore.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-007 A dead connection is visible | Must Have | M |
| US-008 A reconnect doesn't duplicate | Must Have | M |
| US-006 A remote card survives restart | Must Have | M |

### Out of Scope (Deferred)

- The create palette / remote folder picker — Phase 06.

## Implementation Steps

### Step 1: `unreachable` — a state that reaches the screen

**Description:** When the relay's ssh child exits, or keepalives lapse, the card must display
`unreachable`, distinct from `done` and from "not observed."

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/` — add `CardState.unreachable` (per `remote-host-state.md`);
  drive it from the relay supervisor (ssh exit) and the keepalive timeout.
- `app/Sources/GhostlingApp/` — **render** `unreachable` on the card via `BoardTheme.stateColor`.

**Technical Notes:**
- `unreachable` does **not exist** in `app/Sources/` today — `grep -rn unreachable
  app/Sources/` is one unrelated hit (`ghostling-probe/main.swift:25`). **An unrendered enum
  value passes every case that doesn't assert on the screen** — so TC-E2E-020 asserts the
  card's real layer-backed draw with `needsAttention == false`; `cacheDisplay`/`CALayer.render`
  are non-evidence.
- **The keepalive is only argv-deep in automation.** TC-INT-004 asserts the argv carries
  `ServerAliveInterval=15`/`ServerAliveCountMax=3` and drives the timeout source directly —
  it does **not** prove ssh honours them, because ssh is substituted. The real partition
  (drop Tailscale / close lid, no clean ssh exit) is human-verified in TC-E2E-021: card
  reaches `unreachable` in ~45s (15×3), never past 60s, never frozen on `running`.
- The old missed-heartbeat threshold `N` is retired: down = ssh child exit **or** keepalive
  lapse, not a heartbeat count.

**Acceptance Criteria:**
- [ ] US-007 AC-1 (fast path: ssh exits) → `unreachable`.
- [ ] US-007 AC-2 (partition via keepalive) → `unreachable` in ~45s (human).
- [ ] US-007 AC-4: `unreachable` **renders**, distinct from `done`.

**Tests:** TC-E2E-005, **TC-E2E-020 (renders)**, TC-INT-004, **TC-E2E-021 (human,
partition)**

---

### Step 2: Dedup keys — a reconnect can't rewind or double a card

**Description:** After a reconnect, `tail -F` replays lines already seen. Dedup must drop the
replays so a card is never moved backwards or duplicated.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/SignalEvent.swift` / dedup store — two key kinds:
  raw state hooks keyed `(host, sha256(raw line))`; `turn_diff` lines keyed
  `(host, session_id, iteration, sha256(diff_base64))`.

**Technical Notes:**
- **`iteration` is not a unique diff identity.** It increments only on `UserPromptSubmit`;
  `turn_diff` emits on `Stop` reading it *without* incrementing, and `checkpoint` is never
  cleared — so two `Stop`s in one iteration produce two diffs with equal `iteration`, hence
  the `sha256(diff_base64)` tiebreak. The contract landed this by **reading source, not
  trusting the field name.**
- The behaviour the keys protect — a reconnect must not move a card backwards — is asserted
  at E2E (TC-E2E-006), because `done` is sticky and the real regression is a **replay
  extinguishing `waitingForInput`**, not `done` flipping.
- `SignalTimestamp.parse` falls back to arrival time when the timestamp is absent (its final
  `return arrival`) — dedup keys must not depend on a timestamp that may be synthesised.

**Acceptance Criteria:**
- [ ] US-008 AC-1..3: replayed lines are dropped; the card neither duplicates nor rewinds.

**Tests:** TC-E2E-006, TC-INT-003, TC-INT-005, TC-UNIT-008, TC-UNIT-009, TC-UNIT-010,
TC-UNIT-011

---

### Step 3: Persist the spec, rebuild the argv — restart survival

**Description:** A remote card must reappear after an app restart and reconnect its relay.

**Files to Create/Modify:**
- `app/Sources/GhostlingCore/` — `PaneSnapshot.remote` carries the **`RemoteTmuxSpec`
  (the constructor's input)**, not the composed argv. On restore, rebuild via
  `RemoteTmuxCommand.argv(for:)` — which re-applies Phase 01's firewall — and host-qualify
  recents.

**Technical Notes:**
- **DD-003, the persist-the-spec invariant: persist the constructor's input, not its
  output.** The guarantee (no headless smuggling) lives in the shape of what is persisted;
  persisting the argv would relocate the guarantee into restore code and let a hand-edited
  snapshot bypass the firewall. **No `PaneSnapshot` version bump** — the remote case is an
  added variant, not a format change.
- This is the call site that runs **at launch with no human present** — the reason Phase 01
  (DD-004) had to ship first.
- The remote seed passes `projectDir: spec.target`; `SessionRegistry.resolveCwd` falls back
  to home when `directoryExists` fails, so a remote path that can't be stat'd locally does
  not wedge restore.

**Acceptance Criteria:**
- [ ] US-006 AC-1..3: a remote card persists, decodes, rebuilds its argv through the firewall,
  and reconnects.

**Tests:** TC-E2E-007, TC-E2E-008, TC-E2E-009, TC-E2E-010, TC-E2E-011

## Definition of Done

- [ ] US-006, US-007, US-008 all ACs green; US-007 AC-2 human-signed (TC-E2E-021).
- [ ] `unreachable` proven on the real render path (TC-E2E-020), not a cached composite.
- [ ] Restore rebuilds argv through `PoolFirewall`; no argv is persisted.
- [ ] `swift test` count strictly increases; `swift build` warning-clean.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `unreachable` ships as a model value that never renders (the green-but-invisible trap, 4× before) | Medium | High | TC-E2E-020 asserts the real draw with `needsAttention == false`; render-path rules enforced. |
| Keepalive assumed working because the argv carries the flags | Medium | High | The argv assertion is scoped honestly to a claim; the demonstration is human TC-E2E-021. |
| Persisting the argv relocates the firewall guarantee into restore code | Low | High | DD-003 persists the spec; restore rebuilds through `argv(for:)`. |
| Replay rewinds a card because `iteration` was trusted as a diff id | Medium | Medium | sha256 tiebreak; TC-UNIT-008..011 pin the key semantics. |

## Notes

Three stories share this phase because they are one concern — the channel telling the truth
under adverse conditions (death, replay, restart) — and they share the relay + identity
substrate built in Phases 03–04.

## Related

- **Stories:** US-006, US-007, US-008
- **Decisions:** DD-001 (keepalive/down), DD-002 (identity survives restore), DD-003 (persist
  spec), DD-004 (restore argv passes firewall)
- **Contracts:** [remote-host-state.md](../code-changes/remote-host-state.md),
  [remote-spec-snapshot.md](../code-changes/remote-spec-snapshot.md)
- **Tests:** [unit/dedup-keys.md](../test-specs/unit/dedup-keys.md),
  [e2e/remote-card-survives-restart.md](../test-specs/e2e/remote-card-survives-restart.md),
  [e2e/real-linux-host-signoff.md](../test-specs/e2e/real-linux-host-signoff.md)
