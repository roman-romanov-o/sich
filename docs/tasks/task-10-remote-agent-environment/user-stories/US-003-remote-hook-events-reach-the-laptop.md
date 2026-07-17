# US-003: Remote Hook Events Reach the Laptop

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator (the developer running agents on the board)
**Estimated Complexity:** L

## User Story

As an **operator**,
I want to **the hook telemetry from a remote host to arrive on my laptop over the ssh connection I already have**,
So that **a remote session can be watched at all — today it is a terminal and nothing more**.

## Acceptance Criteria

- [ ] **AC-1:** With a per-host relay running, a hook event appended to `~/.ghostling/events.jsonl` on a remote host is normalised on the laptop and reaches the board's session state. Written red first: nothing today reads any file but the local one.
- [ ] **AC-2:** Every relayed line is stamped with `ghostling_host` **at ingestion**, before normalisation. The hook payload has **no hostname field** (zero grep hits across the repo), so host provenance exists for exactly one instant — the channel opened to a known host — and is unrecoverable afterwards.
- [ ] **AC-3:** Relayed lines are **never** written into the local `~/.ghostling/events.jsonl`. The relay feeds the normalizer in memory. Assert the local file's byte length is unchanged across a relay session.
- [ ] **AC-4:** **No inbound listener is added and no new remote binary is distributed.** Assert structurally, not by inspection: the only `NWListener` in the app remains `StaticFileServer.swift:14` (the LikeC4 pane), and the remote side of this story is `ssh` + `tail` and nothing else.
- [ ] **AC-5:** The relay argv passes `PoolFirewall` (US-001) and is generated from a constrained spec, never composed from free text.

## Edge Cases

1. **The remote log rotates**
   - Trigger: `events.jsonl` is `mv`d and recreated.
   - Expected behavior: `tail -F` (`--follow=name --retry`) is a designed match for `mv`-based rotation and picks the new file up. Research doc 02, risk 5.

2. **The relay starts against a host with existing history**
   - Trigger: the file already holds thousands of lines.
   - Expected behavior: `-n 200` bounds the replay. Duplicate suppression across reconnects is US-008's job, not this story's.

3. **The remote file does not exist yet**
   - Trigger: hooks installed but no session has ever run.
   - Expected behavior: `-F`'s `--retry` waits for it rather than the relay exiting. The card must not read as unreachable merely because the file is absent.

## Technical Notes

Per-host command (DD-001):
`ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 <target> 'tail -n 200 -F ~/.ghostling/events.jsonl'`

Why an in-memory relay rather than appending to the local sink: merging remote lines into the shared local file **destroys host provenance irreversibly**, and the risk is live rather than theoretical — a remote **macOS** host with `/Users/roman/proj` and a local card at `/Users/roman/proj` emit byte-identical `cwd`, so the directory join in `BoardShell.applySessions` (its `liveState(forDir:id:joinByDir:in:)` call) would move the **local** card. Remote OS is "both/varies", so this is a real configuration, not a contrived one.

This preserves task-03's DD-002 observe-only sink: no server, no port, no reply, no listener.

## Dependencies

- **Requires:** US-001 (the relay is one of the new ssh-emitting call sites).
- **Enables:** US-004 (identity binding needs events to bind), US-007 (liveness rides this transport), US-008 (dedup covers this transport's reconnect).

## Execution History

| Iteration | Phase | Result | Notes |
|-----------|-------|--------|-------|
| - | - | - | Not yet executed |

## Questions

- [ ] Does the relay own its own ssh connection, or multiplex over the ⌘⇧R session's `ControlMaster`? A second connection is simpler and independently supervisable; multiplexing halves the auth cost. Latency is not the deciding factor.

## Related

- Task: [task-description.md](../task-description.md) — success criteria 1, 9
- Design Decision: [DD-001](../design-decisions/DD-001-remote-hook-telemetry-transport.md)
- Research: [research/02-hook-telemetry-transport.md](../research/02-hook-telemetry-transport.md)
