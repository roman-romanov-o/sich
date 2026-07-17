# US-002: Turn Diffs From a Linux Host

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator (the developer running agents on the board)
**Estimated Complexity:** M

## User Story

As an **operator**,
I want to **see per-turn diffs in drill-in for a session running on a Linux box, exactly as I do for a local macOS one**,
So that **I can review what the agent changed without leaving the board, on whichever machine the work happens to be running**.

## Acceptance Criteria

- [ ] **AC-1:** An automated fixture runs the forwarder under **GNU coreutils semantics** — no `plutil` available, and `base64` wrapping output at 76 columns — and the resulting event line carries a well-formed `session`, `cwd` and diff payload. Written red first: today the forwarder's three `plutil -extract` calls gates the entire diff block on three `/usr/bin/plutil -extract` calls, so under Linux they fail, `$session`/`$cwd` come back empty, and diffs are **silently skipped** while the raw append at `:140` still succeeds.
- [ ] **AC-2:** A **human sign-off** run against a real Linux host: drill into a remote card, take a turn, see the diff render. Recorded in this file with the date. This AC is not auto-passable and must never be marked done by a test.

## Edge Cases

1. **`base64` line-wrapping**
   - Trigger: GNU `base64` wraps at 76 columns; BSD `base64` does not.
   - Expected behavior: the payload survives. It currently does — by **luck**, via `tr -d '\n'` (the forwarder's `base64 | tr -d '\n'`) — not by design. A fixture that stubs only `plutil` catches none of this and does **not** satisfy AC-1.

2. **Another undiscovered coreutils divergence**
   - Trigger: any of `sed`, `date`, `stat`, `readlink`, `mktemp` behaving differently under GNU userland.
   - Expected behavior: the audit is the work, not the `plutil` removal. Every external command the forwarder invokes gets checked against both userlands; findings are listed in the story before implementation closes.

3. **The forwarder degrades rather than failing loudly**
   - Trigger: a portability bug that silently empties a field.
   - Expected behavior: this is the shipped bug's exact shape and the reason for AC-1. A missing diff must be distinguishable from "no changes this turn"; silent skip is the failure mode under test.

## Technical Notes

The two ACs are deliberately in **one** story. The fixture without the human check is precisely this repo's recurring green-but-wrong trap (see `unfaithful-capture-and-render-path-fix`): a capture path can report success while nothing renders. Splitting them would let the automated half close as "done" while the feature does not work.

The forwarder must stay POSIX and must never block on network I/O — its "never slow the watched session" contract (the forwarder's never-block contract comment) is unaffected by this story and must remain true after it.

## Dependencies

- **Requires:** nothing hard, but a real Linux host with hooks installed (US-005) is needed to *perform* AC-2's sign-off. AC-1 needs only the fixture.
- **Enables:** US-005 (installs this forwarder remotely), and the diff half of the task's demo.

## Execution History

| Iteration | Phase | Result | Notes |
|-----------|-------|--------|-------|
| - | - | - | Not yet executed |

## Questions

- [ ] Which Linux host does AC-2's sign-off run against, and does it already have Claude Code installed?
- [ ] Is `jq` present on the remote hosts, or must the forwarder keep parsing JSON with shell builtins? This decides how much of the `plutil` removal is a rewrite versus a substitution.

## Related

- Task: [task-description.md](../task-description.md) — success criterion 2, bug 1
- Research: [research/02-hook-telemetry-transport.md](../research/02-hook-telemetry-transport.md)
