# DD-004: PoolFirewall — Inspecting the Command Behind `ssh`

**Status:** Proposed
**Date:** 2026-07-17
**Deciders:** Roman Romanov (product), planning session
**Resolves:** the task-description's Technical constraint *"This task must extend
`PoolFirewall` to inspect the remote command when `argv[0]` is ssh"* — which, until
this DD, **no decision owned**. Raised by the DD reviewer, 2026-07-17.

## Context

The watcher-not-spawner rule is this product's economic invariant: ghostling must
never auto-launch `claude -p`, because that silently spends the API-credit pool
instead of the interactive subscription (`PoolFirewall.swift:3-9`). The firewall is
described in-code as **structural, not advisory** (`:30-34`).

Against ssh, it is neither. Verified at `PoolFirewall.swift:41-46`:

```swift
public static func classify(_ argv: [String]) throws -> Pool {
    guard let executable = argv.first else { throw PoolViolation.emptyCommand }
    if isClaude(executable) {                    // ← "ssh" is not "claude"
        try assertNoHeadlessFlag(in: argv.dropFirst())
    }
    return .interactive                          // ← so ssh returns clean, uninspected
}
```

`isClaude` compares `lastPathComponent == "claude"` (`:49-51`), so
`["/usr/bin/ssh", "host", "claude -p 'do the thing'"]` short-circuits the only check
and classifies as `.interactive`. Local `claude -p` **is** still caught; the remote
path simply is not covered, because before TASK-10 nothing generated ssh argvs on a
spawn path worth guarding.

TASK-10 changes that. It adds ssh-command-emitting call sites:

1. `installRemote(host:)` — DD-001's hook installer.
2. The per-host `tail -F` telemetry transport — DD-001.
3. **The spec-based restore path — DD-003**, which rebuilds an ssh argv from a
   persisted snapshot and runs it. This one is the sharpest: it runs at launch,
   from data on disk, without a human in the loop.

Until this DD, the constraint was enforced by code review only — which the
task-description itself calls *"aspirational."*

### Constraints

- **`PTYSession.swift:34` is the chokepoint** — it calls `PoolFirewall.classify`
  before spawning. Extending `classify` covers every spawn path, including ones
  TASK-10 has not thought of.
- **`reopenShell` (`SessionRegistry.swift:250-255`) is the *only* firewall gate on
  the restore path**, and DD-003's restore does not go through it.
- **The user can type a session name and a destination** (⌘⇧R today, the palette
  later). Free text reaches argv construction.
- **A remote command is a *string*, parsed by a remote shell we do not control.**
  Quoting, aliases, `$PATH`, shell functions, and `sh -c` all sit between our string
  and what actually executes.
- **No new dependencies** (task-description).

### Requirements

- Criterion **9**'s sibling constraint: the two new ssh call sites must not be able
  to route work to the headless pool.
- Must not break DD-001's transport or DD-002's binding, both of which legitimately
  send non-`claude` remote commands (`tail -F`, `tmux new-session`).

## The honest framing this decision turns on

It is tempting to state the goal as *"make it impossible to run `claude -p` on a
remote host."* **That goal is not achievable and pretending otherwise would be worse
than not trying.** The remote command is a string interpreted by a shell we do not
control. `cl''aude -p`, `$X -p` with `X=claude`, an alias, a wrapper script, or a
`claude` binary renamed `foo` all defeat any scan we could write. A user with ssh
access to their own machine can always run whatever they want there — and *should*
be able to; that is their box.

The real goal is narrower and fully achievable: **ghostling must never be the thing
that launches headless work.** The invariant protects the user from *our* automation
spending their credits, not from themselves. Once framed that way, the answer
follows: the guarantee belongs at **construction** (what argvs can we generate?),
with inspection as a secondary net for the case where a human typed something they
will regret.

This mirrors DD-003's reasoning exactly — prefer a structural guarantee over a
coding one — and the two decisions are stronger together than either alone.

## Options Considered

### Option 1: Parse the ssh argv and scan the remote command for headless flags

**Description:** Teach `classify` that when `argv[0]` is `ssh`, it must skip ssh's
own options (handling the arg-taking ones: `-p -i -o -l -L -R -D -F -E -b -c -m -O
-Q -S -W -w`), find the destination, treat the remainder as the remote command,
tokenize it, and run `assertNoHeadlessFlag` over it.

**Pros:**
- Catches the honest case — a user typing `claude -p` into the remote field.
- Reuses `assertNoHeadlessFlag` unchanged.
- Self-contained; no new dependency.

**Cons:**
- **Unsound, and invites being trusted as sound.** Every evasion above passes. A
  check that looks structural but is a substring scan is worse than an honest
  best-effort label, because the next author will believe it.
- Requires re-implementing ssh's option grammar, which drifts between versions and
  is a genuine source of bugs (miss an arg-taking flag and the destination parse
  slides).
- Tokenizing a remote command means implementing shell word-splitting, which is
  either wrong or large.

**Effort:** Medium. **Rejected as the primary mechanism** — kept, downgraded, as a
secondary net (see Decision).

### Option 2: Refuse *any* ssh argv on a spawn path

**Description:** `classify` throws for `argv[0] == "ssh"`, full stop.

**Pros:**
- Trivially sound; zero parsing.

**Cons:**
- **Kills the feature.** DD-001's transport and DD-002's binding are both ssh
  commands on spawn paths. Would have to be immediately riddled with exceptions,
  which is Option 3 with worse ergonomics.

**Effort:** Trivial. **Rejected — fails the task.**

### Option 3: Structural — ssh argvs may only be *generated*, never *supplied*

**Description:** Make the constrained-spec constructor the only way an ssh argv can
reach a spawn path.

- `RemoteTmuxCommand.argv(for: RemoteTmuxSpec)` already works this way: it takes a
  struct of `{host, user?, sessionName, port?, identityFile?, remoteDir?}` and emits
  argv (`RemoteTmuxCommand.swift:102-119`). No field is *named* like a command.

  **But "no field can hold a command" is false today, and this DD must fix it before
  it may claim it.** Caught in review, 2026-07-17. Two of those fields reach ssh's
  own **option position**, which is strictly worse than the remote-command position
  — ssh options execute **locally**:

  - `sessionName` is genuinely defended, but **not by the sanitizer**.
    `sanitizeSessionName` (`:97-100`) only folds `.: \t` to `-`; it does not touch
    `'` or `;`. The actual defense is `remoteQuoted` (`:131-133`), which single-quotes
    and escapes. Correct behaviour, misattributed — see Implementation Notes.
  - **`host` has no defense at all.** `argv(for:)` applies `trimmingCharacters` and a
    non-empty guard (`:103-104`), then `argv.append(target)` (`:116`). There is no
    leading-dash guard and no host grammar anywhere in `Sources/` or `Tests/`
    (verified by grep). `host` is raw user text: `RemoteTmuxSpec.parse(destination:)`
    (`:46-68`) takes the `NSTextField` string from `promptRemoteTmux`
    (`BoardShell.promptRemoteTmux`), strips an optional `user@` and a trailing `:<int>`, and
    assigns **whatever remains** to `host`.
  - `user` is equally unguarded, and `target` is built as `"\(user)@\(host)"`
    (`:114-115`) — so a dash-leading `user` produces a dash-leading target too. The
    check therefore belongs on **`target`**, not on `host` alone.

  A destination of `-oProxyCommand=sh -c 'claude -p …'` survives `parse` intact
  (no `@`, no trailing `:<int>`), lands in argv as a single dash-leading token before
  any non-option argument, and ssh parses it as `-o`. ProxyCommand is then executed
  **on the local machine** — spending the headless pool, spawned by ghostling, and
  classifying clean today because `argv[0]` is ssh. Note the payload runs even though
  the connection then fails: ssh runs ProxyCommand while resolving the destination.

  This is not a tangent — it is the exact premise this option rests on, and DD-003
  compounds it by persisting `host` and rebuilding the argv **at launch, from disk,
  with no human in the loop**. So Option 3 is only sound *with* the input constraints
  below, which this DD hereby owns rather than assumes.
- Add the two DD-001 call sites as sibling constructors on the same pattern — one
  for `installRemote`, one for the `tail -F` transport — each emitting a fixed
  remote command shape from constrained inputs.
- The remote command each constructor emits is a **closed set**: `tmux new-session
  -A …`, `tail -n 200 -F …`, the installer's script. None is caller-controlled.
- **The constructor must constrain its inputs** (new, and load-bearing): `argv(for:)`
  validates the destination against a grammar — hostname / IPv4 / bracketed IPv6 /
  ssh alias — and **rejects a leading `-`** outright, throwing a new
  `Invalid.invalidDestination`. Without this the "closed set" claim above is untrue.

  **Guard the exact string appended at `:116` — *not* `spec.target`.** These are two
  different values and the difference is a live bypass (caught in review, round 3):

  - `RemoteTmuxSpec.target` (the computed property, `:36-40`) interpolates
    **untrimmed** `spec.host`.
  - The token actually appended is rebuilt at `:114-116` from the **trimmed** host
    (`:103`).

  So a spec with `host: " -oProxyCommand=sh -c 'claude -p …'"` (note the leading
  space) passes a `spec.target` check — it starts with a space, not `-` — and is then
  trimmed into `-oProxyCommand=…` before being appended. Validate **post-trim**, on
  the value that reaches argv. `parse()` trims at `:49`, so ⌘⇧R is protected by
  accident; **DD-003 persists `host` into the snapshot without going through
  `parse()`**, which is exactly the launch-from-disk-no-human path this DD calls its
  sharpest risk. Guarding the wrong `target` would leave that path open.

  A grammar check on the composed destination subsumes `user`, since `user` only
  reaches argv through it (`:114-115`) — no separate `user` guard is needed.

  **Delete the dead store at `:114`** (`var target = spec.target`, immediately
  overwritten by both branches) as part of this change. It is what makes
  `spec.target` read like the value being appended when it is not, and leaving it
  invites the same misreading back in.
- **`port` and `identityFile` are safe, and the reason must be recorded, because it
  is a property of emission order rather than of the values.** Each is positionally
  consumed by a preceding flag — `argv += ["-p", String(port)]` (`:109`), `argv +=
  ["-i", …]` (`:110-112`) — so ssh binds the next token as that flag's argument and a
  dash-leading value cannot be reparsed as an option. (`port` is an `Int`, so `-5`
  stringifies harmlessly; `identityFile` is not reachable from `parse()` at all today
  — only via DD-003's snapshot.) **A future refactor that emits a value without its
  flag reintroduces the hole**, so this is a constraint on the emission order, not an
  observation about these fields.
- The shape check validates the **destination position**, not merely "known flags +
  known remote-command prefix": an option-shaped destination is refused.
- DD-003's restore rebuilds through the *same* constructor from a *spec*, not from a
  persisted argv — which is precisely why DD-003 chose Option 2b.
- `classify` gains an ssh branch that **verifies the shape it expects** rather than
  scanning for badness: an ssh argv reaching the firewall must match a
  constructor-generated form (known flags, known remote-command prefix), and is
  refused otherwise. Failure is closed, not open.

**Pros:**
- **The guarantee becomes real** once the inputs are constrained: with `target`
  validated and `sessionName`/`remoteDir` quoted, no input path reaches either the
  option position or the remote-command position, so ghostling cannot *generate* an
  argv that runs `claude -p`. Stated as an obligation this DD takes on, not as a
  property the code already has — it does not (see above).
- **Composes with DD-003.** Spec-in / argv-out at both create and restore means the
  format, the restore path, and the firewall all constrain the same closed set.
- No ssh option-grammar re-implementation, no shell tokenizer.
- The user's free text lands in `sessionName` / `host` / `remoteDir` — positions that
  are **constrained (`target`) or shell-quoted (`sessionName`, `remoteDir`)** and so
  cannot reach a command position. The quoting exists today (`remoteQuoted`,
  `:131-133`); the `target` constraint is new work this DD requires.
- Fails closed: an unrecognized ssh argv is refused, so a future call site that
  bypasses the constructors gets a test failure, not a silent pass.

**Cons:**
- **It does not stop the user's own remote shell.** Once the tmux pane is open, the
  user can type `claude -p` themselves. Accepted — see the framing above; that is
  their machine and their choice, and it is not ghostling automating anything.
- Adding a legitimate new ssh call site now requires adding a constructor rather
  than assembling argv inline. That is the intended friction, but it is friction.
- The shape check must be kept in sync with the constructors; a drift means a
  refusal (loud) rather than a leak (silent), which is the right failure direction
  but still a maintenance cost.

**Effort:** Low-Medium. Most of it exists — `RemoteTmuxCommand.argv` is already the
pattern; this generalizes it and makes the firewall aware of it.

## Decision

**Chosen Option:** **Option 3 (structural) as the guarantee — with its input
constraints treated as part of the decision, not as implementation detail — plus
Option 1's scan as an explicitly-labelled best-effort net.**

### Rationale

The invariant this project actually needs is "ghostling never spawns headless work,"
and Option 3 delivers exactly that, by the same means the codebase already uses in
two other places (`PoolFirewall`'s chokepoint, `SessionSnapshot`'s persisted shape):
make the bad state unrepresentable rather than detected.

**Precisely, because the loose version of this sentence is what went wrong twice:**
the remote-command *position* is not caller data — quoting (`remoteQuoted`,
`:131-133`) closes it, and that part needs no parser. The **destination position
is** caller data, and this DD constrains it. An earlier draft said "the remote
command is not caller data at any point, so there is no input to sanitize," which is
the exact sentence a future reader would cite to skip the destination guard — the
failure Key Factor 6 exists to prevent. Struck in review, round 3.

Option 1 is retained **underneath** Option 3, not instead of it, and only for the
one case Option 3 leaves open where a warning is still useful: a human typing a
destination string containing a headless invocation. It runs, it throws
`headlessClaudeForbidden` when it matches, and it is documented in-code as
**best-effort and deliberately not sound** — it will not catch `cl''aude -p`, and it
is not supposed to be what stands between us and the constraint. Writing that
sentence in the source is part of this decision, because the failure mode here is
not "the scan misses something," it is "a future reader assumes the scan is the
guarantee."

Option 2's instinct (refuse ssh) is right about direction and wrong about
granularity. Option 3 is Option 2 with a closed allowlist instead of a closed door.

### Key Factors

1. **The achievable goal is "we never spawn it," not "it can never run."** Every
   other option's cost/benefit changes once that is stated plainly.
2. **The remote command must not be caller data** — then no parser is needed.
3. **DD-003's restore path is the sharpest risk** (runs at launch, from disk, no
   human), and it is covered because DD-003 persists a spec, not an argv.
4. **`PTYSession:34` already chokepoints every spawn** — extending `classify`
   inherits full coverage for free.
5. **A scan that looks sound is a liability**; labelled best-effort, it is a net.
6. **A structural claim is only as good as its inputs.** This DD asserted "no field
   can hold a command" while `host` sat unvalidated in ssh's *option* position — the
   most dangerous position in the argv, since options execute locally. The lesson is
   general and worth stating: "the shape can't express it" must be **verified at
   every field**, not inferred from the field *names*. A struct is not a constraint;
   its constructor is.

## Consequences

### Positive

- **It closes a live local-execution hole that exists in shipped code today.** The
  ⌘⇧R destination field currently accepts `-oProxyCommand=…`, which ssh runs on *this*
  machine. That is a watcher-invariant breach reachable from the UI right now, found
  while writing this DD (review, 2026-07-17) — not a hypothetical this task invents.
  It is also the strongest argument for DD-004 shipping first.
- The task-description's "must extend `PoolFirewall`" constraint stops being
  aspirational and becomes a test.
- DD-003's restore path and DD-001's two call sites are all covered by one rule.
- A future ssh call site that skips the constructors **fails closed** and loudly.
- `claude -p` typed into the remote destination field is refused at creation with a
  real error, not discovered on the bill.

### Negative

- **A user can still run `claude -p` inside their own remote tmux pane, and nothing
  here prevents that.** Stated plainly so no one mistakes this DD's scope. If that
  ever needs addressing, it is a different mechanism (remote-side policy) and a
  different decision.
- The best-effort scan will produce occasional false confidence despite the
  docstring. Mitigated only by the docstring and by the structural layer beneath it
  doing the real work.
- Slight friction adding ssh call sites (constructor required).

### Neutral

- `PoolViolation` may gain a case (e.g. `unrecognizedRemoteCommand`) for the
  fails-closed path; the existing two cases are unchanged.
- Local behaviour is completely unchanged — `isClaude` still gates the local check.

## Implementation Notes

Sequencing: **this lands first.** Per the user's decision (2026-07-17), DD-004 ships
before `installRemote`, before the tail transport, and before the spec-based restore
— so the guard exists at the moment the call sites appear, rather than being
retrofitted around code already written to work without it. Retrofitting is how a
firewall ends up shaped like the thing it was supposed to constrain.

Tests must assert the **refusal**, per `interaction-ac-binding-rule`'s spirit — the
negative is the load-bearing half, exactly as in criterion 6:

- `classify(["/usr/bin/ssh", "host", "claude -p 'x'"])` **throws**.
- **`RemoteTmuxSpec.parse(destination: "-oProxyCommand=sh -c 'claude -p x'")` →
  argv construction throws `Invalid.invalidDestination`**, and `classify` of a
  hand-built equivalent throws. This is the regression test for the hole review
  found; write it **red first** — it passes trivially today only because nothing
  throws, so a green-on-arrival version proves nothing.
- The same, with the payload in `user` (`-oProxyCommand=…@host`) — the guard is on
  the composed destination, so assert that, not just `host`.
- **A `RemoteTmuxSpec` built *directly* (not via `parse`) with
  `host: " -oProxyCommand=…"` — leading whitespace — also throws.** This is the
  DD-003 snapshot path, which never calls `parse()` and so never gets its trim
  (`:49`). It is the test that distinguishes guarding `spec.target` (passes — starts
  with a space) from guarding the appended token (throws). Without it, the wrong
  guard ships green.
- DD-002's `new-session` argv **passes** — written against DD-002's *final* command
  shape (which adds `tmux set-environment …;` before the exec), not today's.
- A `RemoteTmuxSpec` whose `sessionName` is `"x'; claude -p 'y"` produces an argv
  whose remote command cannot break out of its quoting. **The defense under test is
  `remoteQuoted` (`:131-133`), NOT `sanitizeSessionName`** — the sanitizer folds only
  `.: \t` and never touches `'` or `;`. An earlier draft of this DD credited the
  sanitizer, which would point the implementer at hardening the wrong function while
  the real defense stayed untested and the test passed anyway. Assert the quoting
  boundary directly.
- A snapshot-restore of a remote pane **throws** rather than spawning, when the
  rebuilt argv fails the shape check.
- DD-001's `tail -F` transport argv and DD-002's `new-session` argv both **pass** —
  a firewall that blocks the feature is not a passing test either.

Do **not** implement the scan by looking for the substring `claude` in the joined
argv: `tmux new-session -A -s claude-work` contains it. Match on a tokenized
argument boundary, and accept that this is best-effort regardless.

## Related

- **Task:** [task-description.md](../task-description.md) — Technical constraint on
  `PoolFirewall`; criterion 9
- **Enables:** [DD-003](DD-003-location-model-and-remote-restore.md) — hard
  prerequisite for its spec-based restore path
- **Guards:** [DD-001](DD-001-remote-hook-telemetry-transport.md) — `installRemote`
  and the `tail -F` transport, its two new ssh call sites
- **Related:** [DD-002](DD-002-remote-card-identity-binding.md) — the
  `new-session` argv this must allow

## References

- `app/Sources/GhostlingCore/PoolFirewall.swift:3-9` — the economic invariant
- `app/Sources/GhostlingCore/PoolFirewall.swift:30-34` — "structural, not advisory"
- `app/Sources/GhostlingCore/PoolFirewall.swift:41-46, 49-51` — `isClaude(argv[0])`;
  ssh short-circuits the check
- `app/Sources/GhostlingCore/PTYSession.swift:34` — the `classify` chokepoint
- `app/Sources/GhostlingCore/SessionRegistry.swift:194-197, 250-255` — restore's only gate
- `app/Sources/GhostlingCore/RemoteTmuxCommand.swift` — `argv(for: RemoteTmuxSpec)`,
  the constructor pattern this generalizes
