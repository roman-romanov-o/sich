# Phase 03: The Relay

**Status:** Not Started
**Estimated Effort:** L
**Dependencies:** Phase 01 (the relay argv passes the firewall), Phase 02 (something writes
the file the relay tails)

## Objective

Carry the remote host's JSONL to the laptop over an in-memory `ssh … tail -F` relay,
stamping each line's host at ingestion, without ever writing a remote line into the local
`events.jsonl` sink. This is DD-001.

## Scope

### Stories Included

| Story | Priority | Complexity |
|-------|----------|------------|
| US-003 Remote hook events reach the laptop | Must Have | L |

### Out of Scope (Deferred)

- Binding a relayed line to the *right card* (identity) — Phase 04. This phase proves lines
  *arrive* and are host-stamped; which card they land on is the next phase.
- Dead-connection state and dedup — Phase 05.

## Implementation Steps

### Step 1: The per-host `ssh tail -F` supervisor

**Description:** For each remote host, run one `ssh … tail -F <file>` child, read its stdout
line-by-line, and feed the existing hook-normalisation path. In-memory only.

**Files to Create/Modify:**
- A new relay supervisor in `app/Sources/GhostlingCore/` (per the
  `remote-hook-event-channel.md` contract) — spawns the child from a **constrained
  `RemoteTmuxSpec`-derived argv**, never a composed string (Phase 01's guarantee).
- `app/Sources/GhostlingCore/HookNormalizer.swift` / `HookSessionStore.swift` — ingestion
  stamps `ghostling_host` (the payload has **no** hostname field; the host is known only
  from *which relay* delivered the line).

**Technical Notes:**
- **The host is stamped at ingestion, not read from the line.** DD-001's load-bearing fact:
  a relayed line is byte-identical to a local one; only the relay that carried it knows the
  host. A line's host cannot come from its content.
- **Relayed lines never touch `events.jsonl`.** The local sink is the local host's; mixing a
  remote line in would give it the local host on the next restart-replay. Remote lines live
  in memory and are re-derived from the relay on every launch.
- `tail -F` = `--follow=name --retry`, matched to the forwarder's `mv -f` rotation at 5 MiB;
  `-n` and `-F` are specified identically to the BSD `tail` the macOS test fixtures run, so
  the fixture is proportionate; the real GNU `tail` runs under TC-E2E-017.

**Acceptance Criteria:**
- [ ] US-003 AC-1..3: a line written on the host appears as a session/state change locally,
  host-stamped, within X (≤5s).
- [ ] AC: no relayed line is present in `events.jsonl` after ingestion.

**Tests:** TC-E2E-001, TC-E2E-002, TC-E2E-003, TC-E2E-004, TC-INT-001, TC-INT-002,
TC-INT-003, TC-INT-006, TC-INT-018

**Note on the E2E seam:** the automated E2E substitutes a **real local child** at the
`relayArgv` seam — real process, real stdout, real exit codes, no mock. The ssh hop itself
is human-verified in TC-E2E-017 (Phase 02's sign-off spec).

---

### Step 2: Prove there is no second listener

**Description:** The relay is a client of `ssh`; it opens no local socket. Guard that
structurally.

**Technical Notes:**
- TC-INT-006 is a **source-grep test**: `NWListener(` appears in exactly one file
  (`StaticFileServer.swift`, at `:25`) — the architecture pane's static server, unrelated to
  the relay. It is honest that a grep catches the *accident* (a new listener sneaks in), not
  an *adversary*.

**Tests:** TC-INT-006

## Definition of Done

- [ ] US-003 all ACs green; the no-`events.jsonl`-contamination assertion holds.
- [ ] `swift test` count strictly increases; `swift build` warning-clean.
- [ ] New relay functions ≲50 lines, single-responsibility (supervisor / reader / stamper
  split).

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| A remote line contaminates `events.jsonl` and mis-hosts on replay | Medium | High | In-memory-only ingestion asserted directly; DD-001 makes the sink local-only by construction. |
| The relay composes an ssh string instead of using a constrained spec | Low | High | Phase 01 is a hard dependency; TC-INT-018 asserts the relay argv passes the firewall. |
| A stray `NWListener` reintroduces a local server | Low | Medium | TC-INT-006 grep guard (accident-level, stated as such). |

## Notes

`X` (freshness bound) = ≤5s; the old threshold `N` was retired at DD-001 (down is detected
by ssh exit + keepalive, not a missed-heartbeat count) — see Phase 05.

## Related

- **Stories:** US-003
- **Decisions:** DD-001
- **Contracts:** [remote-hook-event-channel.md](../code-changes/remote-hook-event-channel.md)
- **Tests:** [integration/relay-transport.md](../test-specs/integration/relay-transport.md)
