# DD-001: Use cmux as a reference implementation, do not fork it

**Status:** Accepted
**Date:** 2026-07-01
**Deciders:** Operator, Claude (from ground-truth investigation of `/Applications/cmux.app`)

## Context

`cmux` is an installed, polished tool the operator already uses (great render,
agent-done notifications, restart resume). It was evaluated as a possible
**fork base** for this project. Ground-truth inspection showed cmux is the
**same stack** as ours — native Swift, embedded Ghostty, Claude-hook detection —
i.e. our architecture one maturity level ahead, but with **no board, no quota,
no mission-control**. The operator is fine open-sourcing under cmux's license,
so licensing is not the deciding factor; the question is purely technical.

### Constraints

- Watcher-not-spawner product invariant must survive any choice.
- Our differentiator (two-flow board, two-pool capacity brain, mission control)
  must not be thrown away.
- Existing Swift+Python codebase is green (60 swift + 66 pytest at last count).

## Options Considered

### Option 1: Fork cmux as the base, graft our board/quota on top
**Pros:** inherit cmux's mature terminal/session/resume code.
**Cons:** cmux has **no board pipeline** — we'd rebuild our whole differentiator on
its app shell; same Ghostty + same hook detection means **no foundation gained**;
our detection pain (the actual problem) is code we own regardless; multi-week.
**Effort:** High.

### Option 2: Lift cmux's terminal/session core into our repo, keep our board
**Pros:** cherry-pick mature subsystems.
**Cons:** their subsystems assume their app lifecycle/state model; integration
friction; still doesn't hand us a board.
**Effort:** Medium-High.

### Option 3: Keep our codebase; treat cmux as a reference impl; port the patterns
**Pros:** keep momentum + green tests + clean provenance (we implement); port only
the four bounded maturity patterns that matter; directly targets the detection-layer
pain the fork wouldn't fix.
**Cons:** we re-implement patterns instead of getting them "for free"; we don't
inherit future cmux fixes.
**Effort:** Medium (days for the core).

## Decision

**Chosen: Option 3.** cmux is a reference implementation of our own architecture,
which is more useful to us than a base to fork.

### Key Factors

1. cmux has no board/quota/mission-control — a fork rebuilds our differentiator for **zero foundational gain** (same engine, same detection design).
2. The stated pain lives in the **detection layer**, which we own in either path — forking doesn't fix it.
3. Our codebase is clean and green; the deficit is four bounded plumbing patterns, not architecture.

## Consequences

- **Positive:** momentum preserved; clean provenance; scope reduced to four ports; the pain is addressed head-on.
- **Negative:** we implement the maturity patterns ourselves (bounded); we don't get cmux's future fixes automatically — we periodically re-inspect it for ideas.
- **Neutral:** cmux stays installed as the operator's daily driver and our living reference.

## Related

- **Task:** `../task-description.md`
- **Stories:** enables US-001..005 (all)
- **Memory:** `cmux-detection-is-hooks-not-terminal-scraping`, `dd-001-embed-libghostty-decision`

## References

- cmux v0.64.6 bundle (`/Applications/cmux.app`) + state dirs (`~/.cmuxterm/`, `~/Library/Application Support/cmux/`).
