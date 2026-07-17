# Integration Test Spec: Relay Transport

**Related:** US-003, US-007, US-008, [code-changes/remote-hook-event-channel.md](../../code-changes/remote-hook-event-channel.md)
**Priority:** Critical
**Status:** Draft
**Suite:** `app/Tests/GhostlingCoreTests/RemoteRelayTests.swift` (new)

## Overview

The transport's behaviour under conditions the E2E spec cannot stage reliably: rotation,
an absent file, keepalive timing, and the memory bound. Real child process, real files —
**zero mocks**. The relay is a process reading a file; mocking either would test the mock.

## Dependencies

- A real child process (`/bin/sh -c 'tail -n 200 -F …'`) at the `relayArgv` seam.
- A temp dir. No network, no sshd.

**One honest gap, stated rather than papered over:** these cases run **BSD `tail`** (macOS),
while production runs **GNU `tail`** on the remote Linux box. `-F` and `-n` are specified
identically in both, so TC-INT-001/002/003 are meaningful — but this is a smaller instance
of the same BSD/GNU blindness these specs refuse to accept for `base64` wrapping and absent
`plutil`. The difference is that those diverge in behaviour and `-F`/`-n` do not, so the
mitigation is proportionate: TC-E2E-017's real Linux host is where GNU `tail` is actually
exercised.

## Test Cases

### TC-INT-001: Rotation is followed (US-003 edge case 1)

**Setup:** relay against `events.jsonl`; `mv` it to `events.jsonl.1`; create a fresh
`events.jsonl`; append a line.

**Expected:** the line arrives. `tail -F` is `--follow=name --retry` — a designed match
against `mv`-based rotation, which is exactly how the forwarder's own rotation block
(`mv -f "$file" "$file.1"` at 5 MiB) rotates. Assert against the real forwarder's
mechanism, not a plausible one.

---

### TC-INT-002: An absent remote file does not read as unreachable (US-003 edge case 3)

**Setup:** relay against a path that does not exist; wait; then create it and append.

**Expected:**
- The card does **not** read `unreachable` merely because no session has ever run.
- The line arrives once the file appears (`--retry` waits rather than exiting).
- The distinction that matters: **`unknown` is "not positively determined"; `unreachable`
  is "positively determined to be gone."** Collapsing them loses the only actionable half.

---

### TC-INT-003: History is bounded on connect (US-003 edge case 2)

**Setup:** a fixture with 5000 lines; connect.

**Expected:** at most 200 lines replayed (`-n 200`). Deduping them is US-008's job, asserted
in TC-INT-005.

---

### TC-INT-004: Keepalive timeout reaches `unreachable` (US-007 AC-2)

**Description:** The **slow path**, asserted separately from TC-E2E-005's fast path. Both
reach the same state; a test that measures only the fast one leaves the slow one unproven.

**Expected:**
- `ServerAliveInterval=15` × `ServerAliveCountMax=3` is present in the relay argv, and the
  ~45s worst case is the asserted bound.
- Assert the **argv carries the options** and that a silent (not exited) child eventually
  yields `unreachable`. Do not sleep 45s in the suite — drive the timeout source
  explicitly, the way `LiveStatusUpdateE2ETests` drives polls rather than waiting on the
  kernel FS watch.

---

### TC-INT-005: The dedup memory bound holds (US-008)

**Setup:** relay 10,000 distinct lines from one host.

**Expected:** the dedup set stays bounded at **500 entries per host, FIFO**. An unbounded
`Set<String>` of every line hash ever seen is a leak that only shows up after hours of
uptime — i.e. never in a test suite that does not assert the bound.

---

### TC-INT-006: The relay adds no listener (US-003 AC-4)

**Expected:** the only `NWListener` in the app remains the LikeC4 pane's, in
`StaticFileServer.swift`. This preserves task-03's DD-002 observe-only sink: no server, no
port, no reply.

**Mechanism, since "asserted structurally" names none and a Swift test cannot enumerate
`NWListener` instantiations:** a **source-grep test** — walk `app/Sources/` and assert that
`NWListener(` appears in exactly one file, `StaticFileServer.swift`. That is a real, cheap,
implementable assertion, and it is honest about its weakness: it greps text, so it catches
the accident (a relay that quietly opens a port) and not the adversary (a listener built
through indirection). The accident is the failure mode in scope.

## Data Fixtures

```swift
// One helper builds every line; specs differ by field, not by format.
func hookLine(event: String, session: String = "s-1",
              cwd: String = "/home/roman/proj", cardID: String? = nil) -> String
```
