# DD-003: Location Model and Remote Card Restore

**Status:** Proposed
**Date:** 2026-07-17
**Deciders:** Roman Romanov (product), planning session
**Resolves:** task-description.md blocker **DD-location**

## Context

Three surfaces need to know that a card lives somewhere other than this machine,
and none of them can express it today:

1. **`PaneSnapshot`** (`SessionSnapshot.swift:41-80`) — persists `cardID`, `title`,
   `taskFolder`, `claudeSessionID`, `cardState`, `wasAlive`, and **no host or argv**.
2. **`PaletteProject`** (`CreateCardPalette.swift:5-10`) — `{path: String, activeCards: Int}`,
   rendered with `abbreviatingWithTildeInPath`.
3. **Recents** (`BoardShell.recentProjectDirs`/`rememberProjectDir`) — a bare `[String]` in
   `UserDefaults.stringArray(forKey: "ghostling.recentProjectDirs")`, capped at 6.

This is the mechanism behind **live bug 2**: a remote card persists
`cwd = "roman@host"` (because `BoardSeed.remoteTmux` sets `projectDir: spec.target`
as a *label*, deliberately — the code comment says so). On restore,
`SessionRegistry`'s `directoryExists(cwd) ? (cwd, false) : (homeDirectory, true)`
fails, and `reopenShell` launches a **local `$SHELL` in `$HOME`** still titled
`roman@host · agent`. The card looks alive and is lying.

The task-description records the reviewer's finding that this cannot be deferred
to `/saha:plan`: criterion 5 (remote card survives restart, reconnects to running
tmux) requires `PaneSnapshot` to gain a host-aware field, and *that is* the
location-model decision.

### Constraints

- **The watcher-not-spawner invariant is located in the persisted *shape*, and this
  decision must not move it.** `SessionSnapshot.swift:6-9` states it outright: *"A
  pane records **cwd + session identity** only — never the agent command — so a
  restore can re-open a shell but can't resurrect a headless agent (the
  watcher-not-spawner invariant lives in the **shape** of what we persist, not just
  the restore code)."* Restated at `:39-40` and `SessionRegistry.swift:194-197`
  (*"the agent command was never stored… so restore can never spawn a print-mode
  headless agent **or any other process**"*). An earlier draft of this DD proposed
  persisting raw `commandOverride: [String]?` and re-running it — which relocates the
  invariant from the shape into restore code, precisely what the docstring says it
  was designed **not** to rely on. Caught in review; Option 2 below is rewritten.
  The one existing exception, `claudeSessionID` (`:47-53`), proves the rule by how
  narrowly it is drawn: it is a *resume token* for a conversation the operator
  already started, explicitly "still not the agent *command*."
- **`reopenShell` is the only `PoolFirewall` gate on the restore path**
  (`SessionRegistry.swift:250-255`), and `PoolFirewall.classify` only inspects
  headless flags when `argv[0]` is `claude` (`PoolFirewall.swift:41-46`) — so an ssh
  argv short-circuits it. Any restore path that runs a command other than
  `reopenShell` is unguarded until **DD-004** lands.
- **Picker scope is a remote recents list, not a tree browser** (user answer,
  2026-07-16). This removed the task's only **L**-sized item.
- **Host count is 2-5** (user answer, 2026-07-16).
- `FolderPicker.swift`'s `FolderPickerView` is **dead production code** (referenced
  only by its own tests). The live picker is `CreateCardPalette` + `BoardShell.chooseFolder`'s
  `NSOpenPanel` (`:972-980`). Building into `FolderPicker.swift` would ship a second
  dead view — the exact trap in `saha-creation-had-no-ui-entry-point`.
- Snapshot `version = 1`, and a snapshot whose version differs is **ignored — start
  clean** (`:11-13`). So a bump is not a migration, it is a data loss; optional new
  fields must be added *without* one, per the `claudeSessionID`/`title` precedent.

### Requirements

- Criterion **5**: remote card survives restart and reconnects to the running tmux
  (regression test, proven red before green).
- Criterion **8**: card creation offers remote as a first-class choice with a
  per-host recents list.
- Criterion **4**: sessions/diffs from two hosts never conflated.

## The finding that shrinks this decision

`BoardSeed.commandOverride` **already carries the full ssh argv**, and remote
`sessionID`s are **already host-namespaced** as `remote/<host>/<session>`. The
information needed to reconstruct a remote card exists at seed time and is simply
dropped at snapshot time.

So bug 2 is likelier *"persist what the seed already knows"* than *"design a
host-aware location type from scratch."* The snapshot half is nearly free. The
palette/recents half needs host-awareness independently of the snapshot half —
the reviewer was right about that, and it is why this stayed a blocker.

**One correction to how this finding was originally read.** "The seed already has
the argv, so persist *the argv*" does not follow, and Option 2a shows why. What the
seed has upstream of the argv is a `RemoteTmuxSpec`; the argv is that spec run
through a constructor. Persisting the *output* of the constructor stores a command;
persisting its *input* stores a location. Both reconstruct the card equally well,
and only one of them keeps the file format unable to name an arbitrary process. The
finding shrinks the decision either way — it just doesn't pick 2a.

## Options Considered

### Option 1: Full `SessionLocation` enum threaded through the stack

**Description:** Introduce `enum SessionLocation { case local(path: String); case remote(host: String, path: String?) }`
and replace `projectDir: String` everywhere — `BoardCard`, `BoardSeed`,
`SessionRegistry`, `PaneSnapshot`, `PaletteProject`, recents.

**Pros:**
- Makes the illegal state unrepresentable; no "nil means local" convention.
- `resolveCwd`'s local-path assumption becomes a **compile error** at every call
  site rather than a silent `$HOME` fallback — the compiler finds bug 2's siblings.
- One concept, uniformly.

**Cons:**
- This is research doc 05's **L**-sized item, scoped for TASK-10b when the picker
  was assumed to be a tree browser. The recents-only answer removed that need.
- Wide blast radius across card/seed/registry/snapshot/restore for a feature whose
  UI is a recents list against 2-5 hosts.
- Large diff competing for the same review budget as the transport (DD-001), which
  is where the genuine risk lives.

**Effort:** High.

### Option 2a: Persist the raw argv + host-qualified recents — **rejected in review**

**Description:** Add `host: String?` and `commandOverride: [String]?` to
`PaneSnapshot`; on restore, re-run the persisted argv instead of `reopenShell`.

**Why it was attractive:** `BoardSeed.commandOverride` already holds the exact ssh
argv, so persisting it is nearly free.

**Why it is rejected:** it makes the persisted shape able to express *any command*,
which is the capability the shape was deliberately built to lack. A persisted
`["/usr/bin/ssh", "-t", "host", "tmux new-session -A -s x 'claude -p …'"]` would
restore clean through both gates — `reopenShell` is bypassed, and
`PoolFirewall.classify` waves ssh through (`PoolFirewall.swift:41-46`). "Restore
can never spawn a headless agent" would become a property of restore code that a
future edit could quietly remove, rather than a property of the file format that
cannot represent the attack at all. Freedom this decision does not need.

**Effort:** Low. **Rejected — trades a structural guarantee for a coding one.**

### Option 2b: Persist the *remote spec*, reconstruct the argv + host-qualified recents (narrow)

**Description:** Two independent, small changes:
- **Snapshot:** add an optional, **structured** `remote: RemoteSpecSnapshot?` to
  `PaneSnapshot` — `{host, user?, sessionName, port?, identityFile?, remoteDir?}`,
  i.e. exactly the `RemoteTmuxSpec` fields and nothing else. **No version bump**
  (see below). On restore, a pane carrying `remote` rebuilds the argv by calling
  `RemoteTmuxCommand.argv(for:)` — the *same* constructor the create path uses —
  and **must not** fall back to `$HOME` if that fails. `nil` means local, unchanged.
- **Recents:** replace the bare `[String]` with a `Codable` entry carrying
  `{host: String?, path: String}`, and give `PaletteProject` the same optional
  host. Migrate the existing `stringArray` by reading it as host-less entries.

**This preserves the invariant in the shape, which is the whole point.** The
persisted form can express "attach to tmux session `<name>` on `<host>`" and
**cannot** express "run an arbitrary command," because the command is not data —
it is generated at restore by code, from constrained fields. That is the same kind of
guarantee `claudeSessionID` has: a token, not a command.

**With one correction, caught in review (2026-07-17).** An earlier draft of this
paragraph claimed a hand-edited snapshot "can at worst name an odd host or session;
it cannot smuggle `claude -p`, because there is no field in which to put it." **That
was false**, and it is exactly the kind of claim this DD elsewhere warns against —
asserting a structural property the code does not yet have. `host` is unconstrained
(`RemoteTmuxCommand.swift:103-104, 116`), so a snapshot naming
`host: "-oProxyCommand=sh -c 'claude -p …'"` would rebuild into an argv where ssh
executes that command **locally**, at launch, with no human present. The field the
payload goes in is `host`.

The conclusion survives, but only because **[DD-004](DD-004-poolfirewall-ssh-command-inspection.md)
constrains `target` in the constructor and is a hard prerequisite of this decision** —
which is why it ships first. The accurate statement is: the persisted form cannot
name a command *because every field it does have is constrained or quoted on the way
into argv*. Not because commands are unnameable in principle — they were, until
DD-004.

It is also the same *narrowing* the existing exception uses — and it costs almost
nothing versus 2a, because `RemoteTmuxCommand.argv(for:)` already exists and is
already unit-tested.

**No version bump.** Both new fields are optional, and the file's own precedent is
explicit that optional additions need none: `claudeSessionID` "decodes to nil from a
pre-resume v1 snapshot, **so no version bump is needed**" (`:47-49`), and `title`
says the same (`:54-57`). Bumping would be actively harmful — `:11-13` says a
snapshot whose version differs is **ignored (start clean)**, so shipping v2 would
silently discard every existing user's restored panes on upgrade. An earlier draft
of this DD called for the bump; that was a bug, caught in review.

**Pros:**
- Directly fixes bug 2 using data that already exists at seed time.
- **Keeps the watcher invariant structural**, where the code says it belongs.
- Small, reviewable, testable diff; the risk budget stays on DD-001.
- No version bump ⇒ no data loss on upgrade; absent field = local.
- Reuses the create path's own argv constructor, so create and restore cannot drift.
- Right-sized to the recents-only picker and 2-5 hosts.

**Cons:**
- **"nil means local" is a convention, not a type guarantee.** Nothing stops a new
  call site from treating a remote card's `projectDir` as a real path — which is
  precisely how bug 2 happened. The compiler will not catch the next one.
- Leaves `projectDir` overloaded as label-or-path for remote cards, i.e. the
  original smell survives.
- Slightly more code than 2a (a small `Codable` struct + a rebuild call) for a
  guarantee that only pays off against a case that "shouldn't happen."

**Effort:** Low-Medium.

### Option 3: Do nothing for the snapshot; treat remote cards as ephemeral

**Description:** Drop remote cards on quit rather than restoring them wrong.

**Pros:**
- Trivial; strictly more honest than today's silent local-shell impostor.

**Cons:**
- **Fails criterion 5 outright.** "Survives restart and reconnects to the running
  tmux" is a large part of why tmux is there at all.

**Effort:** Trivial. **Rejected — fails a success criterion.**

## Decision

**Chosen Option:** **Option 2b — persist the remote *spec* (not the argv) with no
version bump, and host-qualify the recents store.**

### Rationale

The scope answer changed the arithmetic. Option 1's cost was justified when the
picker was a tree browser that had to thread a location type through every surface;
with a recents list against 2-5 hosts, it is a large refactor bought mostly for
type elegance, landing in the same review as a new transport. The transport is
where this task's real risk lives, and it deserves the attention.

Option 2b beats 2a for a reason worth naming, since 2a is the version that "just
persists what the seed has": the invariant this codebase relies on is a property of
the **file format**, not of the restore function. Storing a spec keeps it that way
at a cost of one small struct. Storing an argv would move a guarantee the code
explicitly located in the shape into a code path that DD-004 has to defend forever.
When a structural guarantee and a coding guarantee cost nearly the same, take the
structural one.

Option 2b also exploits the fact that the hard part is already done: the seed has
the spec, and remote `sessionID`s are already `remote/<host>/<session>`. The fix is
to stop discarding information, not to model it anew.

**The honest counter-argument, stated plainly:** Option 1's real advantage is not
elegance, it is that `resolveCwd`'s local-path assumption becomes a compile error
instead of a silent `$HOME` fallback — and a silent fallback is *exactly* how bug 2
shipped. Choosing Option 2 accepts that the next call site could reintroduce the
same class of bug, and buys that risk down with tests rather than types. That is a
weaker guarantee, and it is a deliberate trade, not an oversight.

**Reversal cost: deferral at unchanged-or-higher cost — *not* "low."** The earlier
draft claimed low reversal cost, and that claim does not survive pressure. What is
mechanical is only the persisted schema (the fields are already there, and a
`Codable` struct maps onto the enum cleanly) — and that is the *cheap* part of
Option 1. The expensive part is threading the enum through `BoardCard`, `BoardSeed`,
`SessionRegistry`, `PaneSnapshot`, `PaletteProject`, and recents, and Option 2b
**defers** that cost rather than discounting it. Worse, this task actively adds
*new* call sites written against `projectDir: String` plus the nil convention — the
host-qualified join, the palette host stage, the spec-based restore — so promoting
later is strictly **more** expensive than doing it now, not less.

The decision stands anyway, on the grounds above: the scope answer removed the need
Option 1 was sized for, and the risk budget belongs on DD-001. But it is bought
down with the criterion-5 regression test rather than with types, and it gets more
expensive to undo the longer it waits. That is the honest shape of the trade.

### Key Factors

1. **The recents-only scope answer** removed the need Option 1 was sized for.
2. **The seed already carries the spec** — the snapshot half is nearly free.
3. **The watcher invariant must stay in the persisted shape** — which picks 2b over
   2a, at negligible cost.
4. **Risk budget belongs on DD-001**, which is genuinely novel.
5. **Reversal is deferral, not discount** — accepted with the cost stated, not
   waved away.
6. Criterion 5 rules out Option 3.

## Consequences

### Positive

- Bug 2 fixed: a remote card reconnects to its running tmux instead of
  impersonating a local shell.
- Criteria 5 and 8 satisfiable with a small diff.
- Recents become host-qualified, which criterion 4 needs anyway.

### Negative

- **`projectDir` stays overloaded** for remote cards (label, not path), and
  "nil host means local" remains a convention the compiler cannot enforce. Accepted
  above with eyes open; mitigated by the criterion-5 regression test.
- **The persist-shape invariant is widened, narrowly, and this must be said aloud.**
  Before this DD, a `PaneSnapshot` could name a *directory*. After it, one can name
  a *host and a tmux session* — which is a new kind of reach: restoring a card can
  now cause a process to run on another machine. The invariant's *guarantee* is
  intact (the shape still cannot name a command, so restore still cannot resurrect a
  headless agent) but its *scope* is not what `SessionSnapshot.swift:6-9` was written
  against, and a reader of that docstring would be surprised. The docstring must be
  amended in the same change that adds the field — not left to describe a format that
  no longer exists.
- **Restore gains reach that `PoolFirewall` does not yet cover.** Rebuilding an ssh
  argv at restore runs a command that today's firewall waves through
  (`PoolFirewall.swift:41-46`). Option 2b keeps the *format* safe; it does not make
  the *call site* safe. **DD-004 is a hard prerequisite** — this restore path must
  not ship before the ssh extension does.

### Neutral

- `PaletteProject` gains an optional host; local rendering
  (`abbreviatingWithTildeInPath`) is unchanged when host is nil.
- Recents key `ghostling.recentProjectDirs` changes shape; migrate in place.

## Implementation Notes

Restore must **not** silently fall back. Today's
`directoryExists(cwd) ? (cwd, false) : (homeDirectory, true)` is the fallback that
produced a lying card; for a pane carrying a `remote` spec, rebuild via
`RemoteTmuxCommand.argv(for:)` and run *that*, and if it cannot be run, surface the
failure — do not open a local shell. This is the same "honest degradation, never a
fake zero" rule DD-001 applies to transport-down and DD-002 applies to unbound
sessions.

**Amend the docstrings in the same change.** `SessionSnapshot.swift:6-9` and `:38-40`
currently describe a format that this DD changes. They must be updated to say what
is true afterwards: the shape records cwd + session identity + *optionally, a remote
location* — still never a command — and to state why a location is not a command.
Leaving them stale would make the next reader trust a guarantee whose wording no
longer matches the fields, which is how the original over-read of this decision
happened in the first place.

**Route the rebuilt argv through `PoolFirewall`** (per DD-004), and test that path
with an `ssh … claude -p` spec: the assertion is that restore *refuses*, not that it
happens to construct something benign.

**Build the picker in `CreateCardPalette`, not `FolderPicker.swift`.** The latter is
dead; adding to it ships green-but-unreachable code
(`saha-creation-had-no-ui-entry-point`). Criterion 8 says remote must be a
first-class choice at creation — which also retires the ⌘⇧R NSAlert
(`BoardShell.promptRemoteTmux`) rather than maintaining two divergent creation paths
forever. Per the task-description, that retirement lands in the **final** phase,
since ⌘⇧R is 10a's own demo path until the palette replaces it.

Per `interaction-ac-binding-rule`, the criterion-5 test must be **proven red before
green** and must exercise the real snapshot→restore path, not call the restore
helper directly.

## Related

- **Task:** [task-description.md](../task-description.md) — blocker DD-location
- **Constrains:** `SessionSnapshot.swift:6-9` persist-shape invariant — **amended,
  not broken**, by this decision (a location is added; a command still is not).
  Docstring update is part of the change.
- **Requires:** [DD-004](DD-004-poolfirewall-ssh-command-inspection.md) — the
  spec-based restore path is unguarded without it; hard prerequisite.
- **Related Decisions:** DD-001 (supplies `ghostling_host` at ingestion, which the
  host-qualified join consumes), DD-002 (identity binding — the primary join;
  location is the fallback/label layer)

## References

- `app/Sources/GhostlingCore/SessionSnapshot.swift:6-9, 11-13, 38-40, 41-80` —
  the persist-shape invariant, the ignore-on-version-mismatch rule, and `PaneSnapshot`
- `app/Sources/GhostlingCore/SessionSnapshot.swift:47-53, 54-57` — the
  `claudeSessionID`/`title` precedent: optional fields, **no version bump**
- `app/Sources/GhostlingCore/SessionRegistry.swift:194-197` — "restore can never spawn… any other process"
- `app/Sources/GhostlingCore/PoolFirewall.swift:41-46` — `isClaude(argv[0])` guard; ssh short-circuits
- `app/Sources/GhostlingCore/SessionRegistry.swift:251-253, 275-277` — `reopenShell`, `resolveCwd` fallback
- `app/Sources/GhostlingApp/BoardSeed.swift` — `remoteTmux` sets `projectDir: spec.target`
- `app/Sources/GhostlingApp/CreateCardPalette.swift:5-10` — `PaletteProject`
- `app/Sources/GhostlingApp/BoardShell.swift` — live picker (`chooseFolder`/`NSOpenPanel`), recents store (`recentProjectDirs`/`rememberProjectDir`/`recentDirsKey`). Cited by symbol: this file is uncommitted and its line numbers have decayed every planning round.
- `research/03-remote-file-picker.md` (finding 1: dead `FolderPicker`), `research/05-critical-assessment.md`
