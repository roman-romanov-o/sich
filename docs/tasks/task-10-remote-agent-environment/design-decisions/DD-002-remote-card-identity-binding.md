# DD-002: Remote Card Identity Binding

**Status:** Proposed
**Date:** 2026-07-17
**Deciders:** Roman Romanov (product), planning session
**Resolves:** task-description.md blocker **DD-identity**

## Context

A hook line must be attributable to the card that caused it, or the board moves
the wrong card. Locally this is solved: `GHOSTLING_CARD_ID` rides the environment
into the shell (`BoardSeed.liveTerminal`), the forwarder splices it onto every
hook line, and `BoardShell.applySessions` matches
`observed.boundCardID == card.id.uuidString` (in `BoardShell.applySessions`).

**Remote cards have no identity binding whatsoever today.**
`RemoteTmuxCommand.argv` never exports `GHOSTLING_CARD_ID` — no `-o SendEnv`, no
`export`, no `-e`. And the fallback join cannot rescue it: `BoardSeed.remoteTmux`
sets `projectDir: spec.target` (i.e. the literal string `roman@host`), which never
equals any real `cwd`, so the directory heuristic can never fire for a remote card.

Note that `BoardSeed.remoteTmux` **already mints** `cardID ?? UUID().uuidString`.
The card identity exists; it is simply never transmitted. This is a plumbing gap,
not a missing concept.

### Constraints

- **`tmux new-session -A` inherits the original session's environment on attach.**
  Environment set at create time persists; env supplied on a later attach is ignored.
- **`new-session -e` requires tmux ≥ 3.2** (verified: tmux CHANGES, "CHANGES FROM
  3.1c TO 3.2 — Add -e flag to new-session to set environment variables, like the
  same flag for new-window"). Ubuntu 20.04 ships 3.0a; Debian 11 ships 3.1c. The
  user's remote OS answer was **"both/varies"**, so a ≥3.2 floor is not safe.
- **`HookSessionStore` does not match cards at all.** It keys purely on Claude's
  `session_id` (`bySession: [String: Entry]`). `cwd`/`cardID` ride along as sticky
  attributes and are never used to match. Card matching lives *only* in
  `BoardShell.applySessions`.
- **`sanitizeSessionName` is lossy** (`RemoteTmuxCommand.swift:97-100`):
  `".: \t"` all fold to `-`, so `a.b` and `a:b` both become `a-b`.
- **The session name is free text** from an `NSTextField` in `BoardShell.promptRemoteTmux`,
  and **blank input defaults to the literal `"ghostling"`** for every card
  (`RemoteTmuxSpec.sessionName = "ghostling"`).
- `$TMUX` / `tmux display-message` availability inside a hook subprocess is
  **unverified in-repo** — zero tmux usage anywhere beyond `new-session -A`.

### Requirements

- Satisfies criteria **1** (transitions land on the *correct* card) and **4**
  (two hosts never conflated).
- Must not require a read-side rewrite if avoidable — the local binding chain
  already works and is tested.

## The finding that reframes this decision

Research recorded, as its highest-value finding, that *"`tmux new-session -A` on
attach inherits the ORIGINAL session's env — invalidating the obvious
`GHOSTLING_CARD_ID` identity fix before anyone builds it."*

**That over-reads the evidence.** Inherited environment is only *stale* if a
session name is reused by a *different* card. If session names are card-derived
and unique, the original session's `GHOSTLING_CARD_ID` **is the correct one for
that card**, and inheritance on attach is right rather than wrong. Env inheritance
is a hazard only in the presence of name reuse.

Which exposes the real defect. Today, two remote cards created with the name field
left blank both get `"ghostling"`, and `-A` means they **attach to the same tmux
session**. They are not two sessions colliding — they are *one* session displayed
as two cards. The lossy sanitizer has the same character: `a.b` and `a:b` both
attach to the real session `a-b`, so tmux genuinely cannot tell them apart, and
neither should we.

**This is a card-modeling bug, not an identity bug.** The fix is uniqueness of
`(host, sanitized session name)` across cards — which simultaneously makes env
inheritance correct and stops the board from lying about how many sessions exist.

## Options Considered

### Option 1: Derive identity at hook time from the tmux session name

**Description:** Treat `(host, sanitized session name)` as a natural primary key.
The forwarder asks tmux who it is (`tmux display-message -p '#S'`) and stamps that
instead of a card id. Nothing needs to be injected at create time, so staleness is
impossible by construction.

**Pros:**
- No env injection at all; immune to the `-A` inheritance question entirely.
- Works for sessions ghostling did not create.

**Cons:**
- **Requires `$TMUX` to be present in the hook subprocess's environment — unverified.**
  This is external tmux behaviour with zero precedent in this repo; it would need a
  spike before it could be chosen.
- **Violates the forwarder's never-spawn contract further.** It already shells out
  to `plutil`/`git`; adding a `tmux` round-trip to *every* hook makes it worse on
  the hot path.
- **Needs a read-side rewrite**: a new identity field threaded through the
  normalizer, `HookSessionStore`, and the `applySessions` predicate — none of
  which understand anything but `boundCardID` today.
- The key is only as unique as the naming discipline, which Option 4 has to supply
  regardless — so this buys nothing that Option 2 doesn't.

**Effort:** High (plus an unbudgeted spike). **Rejected.**

### Option 2: Carry `GHOSTLING_CARD_ID` in the pane's launch command, **and set the tmux session environment**

**Description:** Mirror `BoardSeed.liveTerminal`, with one addition tmux forces on
us. Instead of `tmux new-session -A -s <name>`, run:

```
tmux new-session -A -s <name> \
  'tmux set-environment GHOSTLING_CARD_ID <uuid>; GHOSTLING_CARD_ID=<uuid> exec $SHELL -il'
```

On **create**, the launch command binds the first pane's shell *and* writes the id
into the **session** environment, so panes created later (`Ctrl-b c`) inherit it
too. On **attach**, tmux ignores the command argument entirely, but the existing
session already carries the correct value in both places, because names are
card-unique (Option 4 is a required companion).

**The `set-environment` half is load-bearing, not belt-and-braces.** A launch
command sets the *process environment of one shell*, not the tmux session
environment. Without it, `Ctrl-b c` — routine tmux use — yields a pane with no
`GHOSTLING_CARD_ID`, so a `claude` run there emits unbound lines and the card
silently reads "not observed" while the terminal works perfectly. That is
`board-status-bug-was-missing-global-hooks` reproduced remotely, with nothing
visibly wrong. Option 3 conceded this distinction ("sets it in the session
environment *properly*"); the first draft of this DD did not, and that was an
error caught in review.

`set-environment` has no meaningful version floor (tmux 1.0), so this keeps
Option 2's version-independence.

**Pros:**
- **Reuses the exact mechanism that already works locally.** The forwarder's
  splice, `BoardCard.boundCardID`, and the `applySessions:1471` predicate need
  **zero changes**. The remote path becomes the local path.
- **No tmux version floor.** Works on 2.x through 3.x alike.
- Attach-inheritance is *correct*, not tolerated — same card, same id.
- Covers panes the user opens later, which a bare launch command does not.
- Testable purely as argv construction, which `RemoteTmuxCommandTests` already does.

**Cons:**
- Three levels of quoting (ssh → `sh -c` → tmux → `sh -c`). Error-prone, though
  unit-testable and already partly solved by `remoteQuoted`/`shellQuoted`.
- Two mechanisms for one fact (pane env + session env) that can disagree if only
  one is updated. Accepted: both are written once, at create, from the same value.
- Cannot bind a session ghostling did not create (see Consequences).
- Depends on Option 4 for correctness; alone it is unsafe.

**Effort:** Low-Medium.

### Option 3: `tmux new-session -A -s <name> -e GHOSTLING_CARD_ID=<uuid>`

**Description:** Same idea via tmux's dedicated flag.

**Pros:**
- Cleanest syntax; no nested quoting; sets it in the session environment properly
  in one step, rather than Option 2's pane-env + `set-environment` pair.

**Cons:**
- **Requires tmux ≥ 3.2** (verified above), which the "both/varies" OS answer
  rules out. Would need a version probe plus Option 2 as a fallback anyway —
  strictly more machinery than just doing Option 2 everywhere.

**Effort:** Low, but **Rejected on the version floor.**

**Re-examined after review.** The reviewer correctly noted that this option's cost
comparison shifts once Option 2's `set-environment` call is on the table: "strictly
more machinery" is a weaker claim when Option 2 is no longer a one-liner. It is
still the right rejection, but for the narrower reason: a version probe means an
extra round-trip per host plus **two** code paths to test, and Option 2 with
`set-environment` reaches the same end state on every tmux we might meet. Option 3
would buy syntax, not capability.

### Option 4: Card-unique session names + uniqueness enforcement (companion, not alternative)

**Description:** Default the session name to a card-derived unique value
(e.g. `ghostling-<short-uuid>`) instead of the constant `"ghostling"`, and reject
creating a card whose `(host, sanitizeSessionName(name))` already belongs to
another card. Enforce on the **sanitized** name, since that is what tmux sees.

**Pros:**
- Fixes the real defect: two cards silently sharing one tmux session.
- Makes env inheritance correct, which is what unlocks Option 2.
- Catches the lossy-sanitizer collision (`a.b` vs `a:b`) at the only layer that can.

**Cons:**
- Changes visible behaviour: the blank-name default is no longer `"ghostling"`.
- Uniqueness is enforced across *cards*, not against remote reality — a user may
  still legitimately type an existing remote session name to adopt it.

**Effort:** Low.

### Option 5: `ssh -o SendEnv` / `AcceptEnv`

**Description:** Forward the variable over the ssh protocol.

**Cons:**
- Requires remote `sshd_config` `AcceptEnv` — server-side config we cannot set for
  the user, silently dropped when absent. A silent failure mode in the exact place
  this project has been burned before (`board-status-bug-was-missing-global-hooks`).

**Effort:** Low. **Rejected on silent failure.**

## Decision

**Chosen Option:** **Option 2 + Option 4 together.** Carry `GHOSTLING_CARD_ID` in
the pane's launch command, mirroring `BoardSeed.liveTerminal`, **and write it to
the tmux session environment via `set-environment` at create** so later panes
inherit it; and make `(host, sanitized session name)` unique per card with a
card-derived default name.

### Rationale

Option 2 is the *same* solution the local path already uses, and reusing a proven,
tested mechanism beats inventing a second identity concept for the remote case.
Its entire read side — forwarder splice, `boundCardID`, the `applySessions`
predicate — is untouched. Remote stops being a special case.

The reason this was not obvious is that the research finding made env look
disqualified. It is not; it is disqualified *only under name reuse*, and name
reuse was an unrelated bug that needed fixing anyway. Option 4 is therefore not
overhead bought to enable Option 2 — it is a defect fix that happens to make
Option 2 sound. Fixing the card-modeling bug and fixing identity are the same act.

Option 1 was genuinely attractive (identity derived rather than carried, staleness
impossible) and was pursued until two facts killed it: `$TMUX`-in-hook is
unverified external behaviour requiring a spike, and it would need the read-side
rewrite that Option 2 avoids entirely. It also still depends on naming discipline,
so it does not escape Option 4.

### Key Factors

1. **Reuse of a proven mechanism** — zero read-side change, versus a new identity
   field threaded through normalizer + store + predicate.
2. **No tmux version floor** — decisive given "both/varies" remote OS.
3. **The blocker was mis-scoped** — env inheritance is a hazard only under name
   reuse, which is an independent bug.
4. **`$TMUX`-in-hook is unverified** — not a foundation to build a blocker's
   resolution on.
5. **Silent failure is the enemy** — rules out `SendEnv` (Option 5).

## Consequences

### Positive

- Criterion 1 satisfiable with the existing, tested binding chain.
- A real defect (two cards → one tmux session) is fixed as a side effect.
- The lossy sanitizer stops being a correctness risk — collisions are rejected at
  creation, on the sanitized name, where tmux's own view is authoritative.
- Remote and local cards bind identically; one mechanism, not two.

### Negative

- **Adopted sessions cannot be observed.** A tmux session ghostling did not create
  has a running shell whose environment we cannot retroactively change
  (`tmux set-environment` affects only *new* panes; the running `claude` keeps its
  old env). **User decision 2026-07-17: such a card attaches and works as a
  terminal but shows an explicit "not observed" badge** — no columns, no diffs.
  Honest degradation over a fake state, per this repo's "never a fake zero" rule.
  Rejected alternatives: blocking adoption (removes the ⌘⇧R use case), and
  relying on `set-environment` to rescue adoption.

  **The scope of that `set-environment` rejection is narrow, and the first draft
  overstated it.** "Looks like a fix, mostly isn't" is true *for adoption* — it
  cannot reach the already-running shell that matters. It is **false** for the
  create path, where `set-environment` is exactly right and is now part of the
  chosen mechanism (Option 2). Two different questions; one sentence had been
  answering both.
- **Nested quoting** (ssh → sh → tmux → sh) is a real hazard. Mitigated by unit
  tests on argv shape.
- The blank-name default changes from `"ghostling"` to a card-derived name.

### Neutral

- `BoardSeed.remoteTmux` already mints a `cardID`; this only transmits it.
- Cards remain free to target an existing remote session name deliberately — the
  uniqueness rule constrains cards against *each other*, not against the remote.

## Implementation Notes

Mirror `BoardSeed.liveTerminal`'s binding, which is the proven reference:

```swift
// local (existing, BoardSeed.swift)
let bind = "GHOSTLING_CARD_ID=\(shellQuoted(id)) "
let launch = "cd \(shellQuoted(projectDir)) && \(bind)exec \(shellQuoted(shell)) -il"

// remote (this decision) — same shape, one more quoting level, plus the
// session-environment write so panes opened later are bound too:
//
//   ssh -t <target> tmux new-session -A -s <name> [-c <dir>] \
//     'tmux set-environment GHOSTLING_CARD_ID <id>; GHOSTLING_CARD_ID=<id> exec <shell> -il'
```

A test must cover the **second pane**, not just the first: create a session, open a
new window inside it, and assert the id is present. Testing only the launch-command
argv would have shipped this DD's original bug green.

**Observability, not inference.** The "not observed" badge must be driven by the
*absence of a bound line*, never by a cached "we created this one" flag — the same
rule criterion 3 imposes on hook-install state. This project has already shipped
"cards never move because hooks weren't installed"
(`board-status-bug-was-missing-global-hooks`); remote reintroduces it with a worse
failure mode, because the terminal works perfectly and nothing looks wrong.

**"Not observed" is ambiguous and must not be shown bare.** Absence of a bound line
has at least three causes: (a) the session was adopted, not created by ghostling;
(b) hooks are not installed on that host; (c) the agent simply has not started yet.
Collapsing them into one badge tells the user something is wrong but not what, and
(b) is actionable while (a) is not. **Criterion 3's probe-derived install state
(`installed` / `not-installed` / `stale-version` / `unknown`) is the surface that
disambiguates (b)**, and the task-description assigns naming that surface to *this*
DD. It is named here: the badge reads the per-host probe state alongside
bound-line absence, and distinguishes at minimum "hooks not installed on <host>"
(actionable) from "this session was not started by ghostling" (not). The probe
itself is owned by criterion 3's story; this DD owns only the requirement that the
badge never fuse the two.

**Testing.** Per `interaction-ac-binding-rule`, the criterion-1 test must prove the
binding end-to-end by feeding a real hook line through the normalizer, not by
calling the matcher directly. Argv shape is unit-testable via
`RemoteTmuxCommandTests`; the uniqueness rule needs a test that a second card with
a colliding *sanitized* name is rejected (`a.b` vs `a:b`).

## Related

- **Task:** [task-description.md](../task-description.md) — blocker DD-identity
- **Related Decisions:** DD-001 (transport — supplies `ghostling_host`; this DD
  supplies `ghostling_card_id`), DD-003 (location model)

## References

- tmux CHANGES, "CHANGES FROM 3.1c TO 3.2" — `-e` added to `new-session`
- `app/Sources/GhostlingApp/BoardSeed.swift` — `liveTerminal` binding (the pattern), `remoteTmux` (the gap)
- `app/Sources/GhostlingApp/BoardShell.swift` — the `boundCardID` predicate inside `applySessions` (cited by symbol: the file is uncommitted and this line has moved every planning round)
- `app/Sources/GhostlingCore/RemoteTmuxCommand.swift:97-100` — lossy `sanitizeSessionName`
- `research/02-hook-telemetry-transport.md`, `research/05-critical-assessment.md`
