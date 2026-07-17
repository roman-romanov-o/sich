# US-006: A Remote Card Survives Restart

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator (the developer running agents on the board)
**Estimated Complexity:** M

## User Story

As an **operator**,
I want to **quit and reopen the app and find my remote card reconnected to the tmux session still running on that host**,
So that **restarting the board does not cost me the work in flight — the reason `tmux -A` was there in the first place**.

## Acceptance Criteria

- [ ] **AC-1:** A remote card restored from disk reconnects to its running remote tmux session. **Proven red before green**: today `BoardSeed.swift:117` sets `projectDir: spec.target`, so the card persists `cwd = "roman@host"`; `SessionRegistry.swift:275-277` does `directoryExists(cwd) ? cwd : homeDirectory`, the check fails, and `reopenShell` (`:251-253`) launches a **local** `$SHELL` in `$HOME` — still titled `roman@host · agent`.
- [ ] **AC-2:** What is persisted is the **spec, not the argv**: `remote: RemoteSpecSnapshot?` = `{host, user?, sessionName, port?, identityFile?, remoteDir?}`, and restore rebuilds the command through the same `RemoteTmuxCommand.argv(for:)` constructor the create path uses. Assert the persisted format **cannot name a command** — no field holds one.
- [ ] **AC-3:** **No `PaneSnapshot` version bump.** Optional fields decode nil (the `claudeSessionID` precedent), and a version mismatch is *ignored* rather than migrated — so a bump is not a migration, it **discards every user's panes**. The behaviour lives in `SessionRegistry.decodeUsable` (`SessionRegistry.swift:172-176`: `snapshot.version == SessionSnapshot.currentVersion else { return nil }`); `SessionSnapshot.swift:11-13` only documents the intent. Assert an old snapshot still restores — the test targets `SessionRegistry`.
- [ ] **AC-4:** A restored remote card rebinds to its session's telemetry (US-004), rather than restoring as an unobserved terminal.
- [ ] **AC-5:** The rebuilt argv passes `PoolFirewall` (US-001). This is the sharpest of the three ssh call sites: it runs **at launch, from data on disk, with no human present**. Sizing note: `reopenShell` already routes through `PoolFirewall.classify` (`SessionRegistry.swift:254`), so this is a **tightening of an existing gate**, not a new one. Precisely: the chokepoint exists but has never been handed an ssh argv — `reopenShell` builds via `Self.shellCommand` (`:251-253`), which always returns a local `/bin/sh -c …`. This story adds the remote branch, and the contract is that it routes through that same chokepoint rather than composing an argv beside it.

## Edge Cases

1. **The remote tmux session died while the app was closed**
   - Trigger: host rebooted.
   - Expected behavior: `-A` creates a fresh session at the same name. The card reconnects to a new session rather than erroring — acceptable, but it must not look like the old work survived.

2. **The host is unreachable at restore time**
   - Trigger: Tailscale down at launch.
   - Expected behavior: the card restores as a remote card in the `unreachable` state (US-007). It must **never** fall back to a local shell — that fallback is bug 2 and is what AC-1 tests.

3. **A hand-edited snapshot**
   - Trigger: the operator (or anything else) edits the JSON.
   - Expected behavior: it can at worst name an odd host or session. It cannot smuggle `claude -p` — **but only because US-001 constrains the constructor's inputs**, which is why US-001 ships first. The persisted format alone does not carry this guarantee; the constructor does.

## Technical Notes

The lesson this story exists to encode (DD-003): when a guarantee lives in a **shape**, adding a feature by widening the shape silently converts it into a guarantee that lives in **code**, and nothing warns you. `SessionSnapshot.swift:6-9` says the watcher invariant lives "in the shape of what we persist, not just the restore code." An earlier draft proposed persisting raw `commandOverride: [String]?` and re-running it — which reads as a small additive change and is actually a reversal: a persisted `["ssh","host","tmux new-session -A -s x 'claude -p …'"]` restores clean through every gate.

**Persist the constructor's input, not its output.** Same power; the format has no field a command can go in.

Honest trade recorded: the full `SessionLocation` enum is deferred, and *not* at a discount. Its real value is not elegance — it is that `resolveCwd`'s local-path assumption would become a **compile error** instead of a silent `$HOME` fallback, which is exactly how bug 2 shipped. This task adds new call sites written against `projectDir: String` plus the nil convention, so promoting the enum later is **more** expensive, not less. Tests were chosen over types deliberately.

Recents are host-qualified (`Codable {host: String?, path: String}`) — see US-009.

## Dependencies

- **Requires:** US-001 (hard prerequisite — see AC-5 and edge case 3), US-004 (rebinding).
- **Enables:** US-009 (the palette writes what this reads).

## Execution History

| Iteration | Phase | Result | Notes |
|-----------|-------|--------|-------|
| - | - | - | Not yet executed |

## Questions

- [ ] `identityFile` is reachable only through this snapshot today (`parse()` never sets it). Should the snapshot decode it at all, or is dropping it the safer default?

## Related

- Task: [task-description.md](../task-description.md) — success criterion 5, bug 2, OQ4
- Design Decision: [DD-003](../design-decisions/DD-003-location-model-and-remote-restore.md), [DD-004](../design-decisions/DD-004-poolfirewall-ssh-command-inspection.md) (prerequisite)
