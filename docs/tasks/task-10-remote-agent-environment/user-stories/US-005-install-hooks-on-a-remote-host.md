# US-005: Install Hooks on a Remote Host

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator setting up a new remote box
**Estimated Complexity:** M

## User Story

As an **operator adding a new remote box**,
I want to **install the hook forwarder on that host from the app, and see truthfully whether it is installed there**,
So that **I know why a card is not moving, instead of staring at a silent board and guessing**.

## Acceptance Criteria

- [ ] **AC-1:** `installRemote(host:)` pushes the forwarder and patches the remote `~/.claude/settings.json`, mirroring what `HookInstaller.installGlobal` (`HookInstaller.installGlobal`) does for the local home. Today nothing installs hooks anywhere but locally.
- [ ] **AC-2:** Per-host install state comes from an **actual remote probe** — reading the remote settings and the forwarder's bytes back over ssh and comparing `sha256(remote bytes)` against `sha256(forwarderScript)`, our embedded copy — and **never** from a locally-cached "I ran installRemote once" flag. A cached flag is the silent-assumption failure this AC exists to prevent, and it would satisfy any looser wording. Assert it by making the probe fail after a successful install and requiring the state to change.
- [ ] **AC-3:** The state set is `installed` / `not-installed` / `stale-version` / `unknown (probe failed)`. `unknown` is distinct and visible, **never** collapsed into `installed`. Assert the negative.
- [ ] **AC-4:** The state is shown on **a host chip on `SessionCard`**, built the same custom-drawn layer-backed way as `repoChip()` (`SessionCard.swift:100`, render path at `:250-261`) — not a stock `NSButton`, which was the lone outlier behind the invisible-pill defect. When the state is `not-installed` or `stale-version` the chip is actionable, and a test proves it by **dispatching a real `NSEvent`** at the chip, red → green. Per this repo's interaction-AC binding rule, an interaction AC proven by calling the handler is an unverified interaction path — this repo shipped that bug three times.
- [ ] **AC-7:** **"Not observed" is never shown bare.** The chip distinguishes "hooks not installed on `<host>`" (actionable) from "not started by ghostling" (not actionable). _(Moved here from US-004 AC-5: it is install-state messaging and belongs with the state machine that owns it.)_
- [ ] **AC-5:** Installation adds **no new remote binary and no new trust surface** — it reuses the existing ssh identity, and what lands on the host is the same shell forwarder the local install writes.
- [ ] **AC-6:** The `installRemote` argv passes `PoolFirewall` (US-001) and is generated from a constrained spec.

## Edge Cases

1. **The remote host already has a hand-edited `settings.json`**
   - Trigger: the operator's own hooks are configured there.
   - Expected behavior: patch, never clobber — the same contract the local installer holds.

2. **The forwarder is present but its bytes differ from ours**
   - Trigger: the app updated; the host did not. (Or the operator hand-edited the remote copy — the hash cannot tell these apart, and the action is the same: re-push ours.)
   - Expected behavior: `stale-version`, distinctly from `installed`. This is the state that makes the probe worth having. Testable **only because** the comparand is now defined — the forwarder carries no version marker on disk (`grep -c version HookInstaller.swift` = 0), so before `/saha:contracts` chose the hash this edge case had nothing that could make it true.

3. **The probe cannot connect**
   - Trigger: host down, Tailscale off, key rejected.
   - Expected behavior: `unknown (probe failed)`, and the reason is available. Not `not-installed` — the app does not know that.

4. **The remote host is macOS**
   - Trigger: remote OS is "both/varies."
   - Expected behavior: the forwarder installed is the portable one from US-002 and works on both userlands. A macOS remote is not a special case.

## Technical Notes

This is the second of the three new ssh-emitting call sites, hence the US-001 dependency.

The honest-degradation rule (`UsageEndpointReader.swift:12-14` — never fabricate a value) is what AC-3 encodes. It is the same rule that produced success criterion 6.

## Dependencies

- **Requires:** US-001 (generated argv), US-002 (the thing being installed must actually run under GNU userland — installing the macOS-only forwarder on a Linux box would produce a card that moves but never shows diffs, silently).
- **Enables:** US-002 AC-2 (the human Linux sign-off needs hooks on a real Linux host), US-003 (no events exist until hooks are installed).

## Execution History

| Iteration | Phase | Result | Notes |
|-----------|-------|--------|-------|
| - | - | - | Not yet executed |

## Questions

- [ ] Is install explicit (the operator asks) or implicit (offered when a host is first used)? Implicit writes to the operator's machine without them asking for it; explicit means the first remote card silently does nothing until they find the button.
- [x] ~~What is the "version" the probe compares against — a string in the forwarder script, or a content hash? A hash makes every local edit look stale.~~ **Resolved at `/saha:contracts`: a content hash** — `sha256` of the remote bytes vs our embedded `forwarderScript`, both hashed on the laptop (no remote hash tool, so no GNU/BSD split). The question's own objection is answered rather than dodged: a local edit *does* make hosts stale, and that is **true**, not a false positive. The marker line was rejected because it can be forgotten, and a forgotten bump reports `installed` while running different code — the silent-failure class this repo keeps re-learning. Full reasoning in [code-changes/remote-host-state.md](../code-changes/remote-host-state.md).

## Related

- Task: [task-description.md](../task-description.md) — success criterion 3
- Code Change: [code-changes/remote-host-state.md](../code-changes/remote-host-state.md) — the state enum and the chip
- Research: [research/02-hook-telemetry-transport.md](../research/02-hook-telemetry-transport.md)
