# E2E Test Spec: A Remote Session Lands On Its Card

**Related Stories:** US-003, US-004, US-007, US-008
**Priority:** Critical
**Status:** Draft
**Suite:** `app/Tests/GhostlingAppTests/RemoteRelayE2ETests.swift` (new)

## Overview

The whole product claim of this task, end to end: a hook line written on a remote host
moves the card the operator started it from, and only that card.

## What this spec does NOT cover, and why it still earns "E2E"

**It substitutes a real local child process for the ssh hop.** Everything else is real —
real JSONL bytes, real `tail -F` semantics against a real file, real process exit, the
real `HookEventTail` → `HookNormalizer` → `HookSessionStore` → `applySessions` chain, real
card state.

The honest name for this is **an E2E of everything except the network hop**, and it is
recorded that way in the coverage matrix rather than as full coverage. The reason is
verified, not assumed:

- `tmux` is **not installed** on this machine.
- `sshd` is **not listening** (`lsof -iTCP:22 -sTCP:LISTEN` → 0 rows).
- CI is `runs-on: [self-hosted, macOS]` — **this same machine**. Hosted macOS cannot link
  the vendored libghostty archives (git-ignored, ~30M) and bills 10× on a private repo.

So "ssh to a second box" is not a test this repo can run on any runner it has. Calling a
loopback-ssh test "E2E remote" would be the exact class of lie this task keeps catching:
a green test whose green means less than its name. The ssh hop is covered by **US-002
AC-2's human sign-off** (see [real-linux-host-signoff.md](real-linux-host-signoff.md)),
which is the established precedent in this task for a non-auto-passable AC.

The seam is `relayArgv(for:)`: the test injects a substitute argv (`/bin/sh -c 'tail -n
200 -F <fixture>'`) at the same boundary the ssh argv is produced. **The argv actually
shipped is asserted separately and exactly** in
[unit/ssh-argv-and-firewall.md](../unit/ssh-argv-and-firewall.md) — so the pair covers
both "the right command is built" and "the bytes it produces are handled right," with the
untested gap being only that ssh transports them faithfully.

## Preconditions

- A temp dir standing in for the remote `~/.ghostling/`, holding an `events.jsonl`.
- Two board cards with distinct UUIDs.
- `ClaudeUsageProbe.spawningEnabled == false` (the default under `swift test`) — nothing
  here spawns an agent.

## Test Cases

### TC-E2E-001: A remote hook line moves its card (US-003 AC-1, US-004 AC-1)

**Written red first.** Nothing today reads any file but the local one; the relay does not
exist, so this cannot pass by accident before the feature lands.

**Steps:**
1. Create card A (`id = <uuid-A>`). Start a relay against the fixture host `roman@boxA`.
2. Append a `SessionStart` line carrying `ghostling_card_id: <uuid-A>`, `cwd: /home/roman/proj`.
3. Pump the tail; drive `applySessions`.
4. Append `UserPromptSubmit`, then `Stop`.

**Expected Results:**
- Card A reads `running` after step 2, and `waitingForInput` after the `Stop`
  (`Stop` = turn-end → waiting; only `SessionEnd` = done).
- Card B never changes state.

**Test Data:**
```json
{"hook_event_name":"SessionStart","session_id":"s-1","cwd":"/home/roman/proj","ghostling_card_id":"<uuid-A>"}
{"hook_event_name":"Stop","session_id":"s-1","cwd":"/home/roman/proj","ghostling_card_id":"<uuid-A>"}
```

---

### TC-E2E-002: `ghostling_host` is stamped at ingestion (US-003 AC-2)

**Description:** The payload has **no hostname field** — zero grep hits across the repo.
Provenance exists for exactly one instant: the channel was opened to a known host. If it
is not stamped there, it is unrecoverable.

**Steps:** relay from `roman@boxA`; append one line with no host field of any kind.

**Expected Results:**
- The `SignalEvent` reaching `HookSessionStore` carries `ghostling_host == "roman@boxA"`.
- Assert the stamp happens **before** normalization — feed a line whose `timestamp` is
  absent, and assert the host is present on the value the normalizer received, not merely
  on the card afterwards.

---

### TC-E2E-003: Two hosts with byte-identical `cwd` are never conflated (US-004 AC-3)

**Description:** The live risk, not a contrived one: remote OS is "both/varies," so a
remote **macOS** host emits `cwd: /Users/roman/proj` exactly as the laptop does.

**Steps:** run two relays (`roman@boxA`, `roman@boxB`) plus a local card, all with
`cwd: /Users/roman/proj`; append one `SessionStart` per host.

**Expected Results:**
- Three distinct sessions. The local card does **not** move.
- Fails loudly if the directory join in `liveState(forDir:id:joinByDir:in:)` is reached
  for a host-stamped event.

---

### TC-E2E-004: Relayed lines never touch the local sink (US-003 AC-3)

**Steps:** record `~/.ghostling/events.jsonl` byte length; run a full relay session of 50
lines; re-read.

**Expected Results:** byte length **unchanged**. Merging remote lines into the shared
local file destroys host provenance irreversibly, so this is asserted structurally rather
than trusted.

---

### TC-E2E-005: A dead connection reads `unreachable`, not `running` (US-007 AC-1, AC-3)

**Steps:** relay a `SessionStart` (card reads `running`); kill the relay child.

**Expected Results:**
- Card reads `unreachable` within **X = 5s** of child exit.
- **The negative assertion is the point:** the card must not read `running` or
  `waitingForInput`. A frozen `running` card is worse than a blank one — it is a lie the
  operator will act on. `unreachable` must also be distinguishable from `unknown`.
- Keepalive (`ServerAliveInterval=15` × `ServerAliveCountMax=3`, ~45s) is **a separate
  case** — see [integration/relay-transport.md](../integration/relay-transport.md)
  TC-INT-004. A test that only measures the fast path leaves the slow path unproven.

---

### TC-E2E-006: Reconnect does not extinguish an attention signal (US-008 AC-1)

**Description:** The example that looks right and is **false**: a replayed
`UserPromptSubmit` does **not** re-open a `done` session — `classify` returns `prior` for
`.userInput` unless prior is `.waitingForInput`/`.idle`, and `done` is sticky. A test
written from that example cannot be made red.

The real hole: `waitingForInput.detectorFallback` is `nil`, so
`settled(.waitingForInput, .running)` = `.running`. **A replayed `SessionStart`/`PostToolUse`
silently extinguishes the attention signal** — the one thing the product exists to raise.

**Steps:**
1. Relay `SessionStart` then `Stop` → card reads `waitingForInput`.
2. Kill the relay. Reconnect (`tail -n 200` replays both lines).

**Expected Results:**
- The card **still** reads `waitingForInput`. Read the AC as "a reconnect does not move a
  card backwards" — stronger than counting events, and the thing that must be asserted.
- A second case: a stale `Stop` against a `running` prior must not de-run a live card.

---

### TC-E2E-020: `unreachable` is visible, and distinct from `done` and "not observed" (US-007 AC-4)

**Description:** TC-E2E-005 asserts the card *reads* `unreachable`. This asserts it
**renders** — and they are not the same claim. `grep -rn unreachable app/Sources/` returns
exactly **one** hit, an unrelated string in `ghostling-probe/main.swift:25`: the state does
not exist and has no render surface. **An unrendered enum value passes every other case in
this spec.**

That is the ship-green-and-broken shape this task keeps catching, and the asymmetry gives
it away: US-005's equivalent rendering AC got a dedicated case with four states and real
click dispatch (TC-E2E-016), while US-007's got nothing.

**Steps:** drive a card to `unreachable`; render the card.

**Expected Results:**
- The card is visibly `unreachable` via the existing state-colour path
  (`BoardTheme.stateColor`), on the **same layer-backed custom-drawn path as TC-E2E-016** —
  `cacheDisplay`/`CALayer.render` are non-evidence here.
- **Distinguishable from `done`** (a different colour, asserted — not merely non-nil) and
  **from "not observed."** All three are quiet states; if they render alike, the operator
  cannot tell "the box is gone" from "nothing has happened yet," which is the whole point
  of `unreachable` existing as its own case.
- `needsAttention == false` — an unreachable host is not an agent asking for you, and
  lighting attention for it dilutes the one signal the product exists to raise.

## Cleanup

Kill every relay child; remove the temp dir. A leaked `tail -F` outlives the test process
and will make the next run's assertions non-deterministic.
