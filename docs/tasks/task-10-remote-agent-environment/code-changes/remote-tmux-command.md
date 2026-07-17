# Code Change: RemoteTmuxCommand + PoolFirewall ssh Inspection

**Type:** Internal interface (module boundary — `GhostlingCore`)
**Consumers:** `BoardShell.promptRemoteTmux` (⌘⇧R card creation), `SessionRegistry.reopenShell`
(restore, US-006), the relay (US-003), `installRemote` (US-005)
**Status:** Draft

## Overview

Every ssh argv the app emits is **generated from a constrained spec, never composed from
free text**. This file is the contract for that constructor and for the firewall beneath
it. It ships **first** (US-001) — retrofitting a firewall around three call sites written
without it is how the firewall ends up shaped like the thing it was meant to constrain.

The framing (DD-004): "make `claude -p` impossible on a remote host" is **not
achievable** — it is a string parsed by a shell we do not control, and `cl''aude -p`,
aliases and wrappers defeat any scan. The achievable goal is "**ghostling** never spawns
headless work." The guarantee is therefore structural; the token scan underneath is
labelled best-effort on purpose. *A scan that looks sound is a liability; labelled
honestly, it is a net.*

## Data Models

### `RemoteTmuxSpec` (exists; extended)

| Field | Type | Required | Validation |
|-------|------|----------|------------|
| `host` | String | Yes | **Non-empty post-trim; must not resolve to an ssh option.** See grammar. |
| `user` | String? | No | Same option check — it composes into the destination. |
| `sessionName` | String | Yes (defaults `"ghostling"`) | Non-empty after `sanitizeSessionName`. |
| `port` | Int? | No | Emitted only as the argument of a preceding `-p`. |
| `identityFile` | String? | No | Emitted only as the argument of a preceding `-i`. |
| `remoteDir` | String? | No | Passed through `remoteQuoted`. |

### Destination grammar (the new guard)

The validated token is **the exact string appended at `RemoteTmuxCommand.swift:116`** —
which is rebuilt from the **trimmed** host (`:104`), *not* the `target` property
(`:36-40`), which composes the **untrimmed** host.

Accepted:

```
destination := [ user "@" ] host [ ":" port ]
host        := hostname | ipv4 | "[" ipv6 "]"
```

- Must **not** begin with `-` after trimming.
- IPv6 literals are accepted in bracketed form (`[::1]`, `user@[fe80::1%en0]`) —
  Tailscale hands out IPv6, so a grammar restricted to `[A-Za-z0-9.-]` would refuse a
  real host. **This resolves US-001's open question.**

### `RemoteTmuxCommand.Invalid` (exists at `:82`; extended)

Nested on **`RemoteTmuxCommand`**, not on `RemoteTmuxSpec`.

| Case | Thrown when | Associated value |
|------|-------------|------------------|
| `emptyHost` | existing (`:105`) | — |
| `emptySessionName` | existing (`:107`) | — |
| **`invalidDestination(String)`** | **new** — the composed destination resolves to an ssh option | **The rejected destination token, verbatim as composed** (post-trim, pre-append) — not the reason, and not the host field alone. The operator needs to see the thing that was refused. |

`Invalid` conforms to `CustomStringConvertible` with an operator-facing `description`
switch (`:86-91`), so the new case must extend it rather than fall through — a case with
no `description` is a dialog with no message. Contract text:

```
"Destination \"<token>\" looks like an ssh option, not a host. Remove the leading dash."
```

The token is interpolated because it is the whole diagnostic: `-oProxyCommand=…` reads as
obviously wrong once shown, and reads as nothing at all when hidden.

## Interface

### `RemoteTmuxSpec.parse(destination:sessionName:remoteDir:) -> RemoteTmuxSpec?`

Note the receiver: `parse` is a static on **`RemoteTmuxSpec`** (`RemoteTmuxCommand.swift:46`),
not on `RemoteTmuxCommand` — the reverse of `Invalid`'s nesting above.

**Signature is unchanged. It does not become throwing.** It is
`public static func parse(...) -> RemoteTmuxSpec?`; making it throw would change **7** call
sites — `BoardShell.promptRemoteTmux`, `RemoteTmuxCardTests.swift:21`, and
`RemoteTmuxCommandTests.swift:74, 82, 90, 98, 99` — and would put the guard where it
**cannot** live: a spec built directly never passes through `parse`.

Two of those sites assert `== nil` (`RemoteTmuxCommandTests.swift:98-99`), and both sit in
the **one** test function `parseRejectsHostless`. So the churn is real but modest; the
reason to keep `parse` Optional is the coverage gap, not the edit count.

`parse` **may** additionally return `nil` for an option-shaped destination. That is a UI
nicety, not the guarantee.

### `destination(for spec: RemoteTmuxSpec) throws -> String`  *(new — the actual chokepoint)*

**This is where the guarantee lives**, and it must be extracted rather than left inside
`argv(for:)`. Trim → grammar check → return the token, or throw
`Invalid.invalidDestination` — **however the spec was built**.

It is separate because **`argv(for:)` cannot serve the other three call sites.** Today it
hardcodes `["/usr/bin/ssh", "-t"]` (`:109`) and unconditionally appends
`remoteScript(session:dir:)` (`:117`), so it can only ever emit the **tmux card** argv. The
relay, the installer and the `staleVersion` probe all need a different remote command — and
if each composes its own destination, US-001's structural guarantee covers **one of four**
ssh call sites while the contract claims it covers all of them. That is the
`-oProxyCommand` hole reopening in the code written to close it.

**Contract: all four emitters obtain their destination token only from `destination(for:)`.
No emitter interpolates `spec.host`, `spec.user`, or `spec.target` into an argv itself.**

| Emitter | Constructor | Story |
|---------|-------------|-------|
| Card | `argv(for:)` — exists | US-004 |
| Relay | `relayArgv(for:)` — **new** | US-003 |
| Install | `installArgv(for:script:)` — **new** | US-005 |
| Probe | `probeArgv(for:)` — **new** | US-005 |

Each is a thin composition: `["/usr/bin/ssh"] + options + [try destination(for: spec)] + [remoteCommand]`.
The `target` property (`:36-40`) composes the **untrimmed** host and must not be used by
any of them — it is the divergence the dead store at `:114` made easy to miss.

### `argv(for spec: RemoteTmuxSpec) throws -> [String]`

The card emitter. Routes its destination through `destination(for:)`.

Live hole this closes: `-oProxyCommand=sh -c 'claude -p x'` has no `@` and no trailing
`:<int>`, so it survives `parse()` whole, reaches `argv.append(target)` (`:116`) in ssh's
**option position**, and ssh executes ProxyCommand **on the local machine**. Options
execute locally, which makes the destination position strictly more dangerous than the
remote-command position. This is reachable from ⌘⇧R in shipped code today.

Also: **delete the dead store at `:114`** (`var target = spec.target`, immediately
overwritten). It is what made the untrimmed/trimmed divergence easy to miss.

### `PoolFirewall.classify(_ argv: [String]) throws -> Pool`

Today it gates `assertNoHeadlessFlag` behind `isClaude(argv.first)`
(`PoolFirewall.swift:41-51`), and `"ssh"` is not `"claude"` — so
`classify(["/usr/bin/ssh", "host", "claude -p 'x'"])` returns `.interactive`
uninspected.

Extension: when the executable is `ssh`, inspect the **remote-command position** for
headless flags as well.

| Rule | Contract |
|------|----------|
| Scope | Only the remote-command operand, not options. |
| Scan | Tokenised, **not** a substring search for `claude` over the joined argv. A session named `claude-work` must pass. |
| Honesty | Best-effort, documented as such. The structural guard is `argv(for:)`. |
| New error | Reuses `PoolViolation.headlessClaudeForbidden(flag:)`. |

**`reopenShell` already routes through `PoolFirewall.classify`
(`SessionRegistry.swift:254`)** — so US-006 AC-5 is a **tightening of an existing gate**,
not a new one.

To be precise about what that buys, since an earlier draft overstated it: the chokepoint
exists, but ssh does not reach it today. `reopenShell` builds its command via
`Self.shellCommand` (`SessionRegistry.swift:251-253`), which always returns
`["/bin/sh", "-c", "cd … exec <shell> -il"]` — never an ssh argv. So the gate is not
"waving ssh through"; it has simply never been handed one. **US-006 adds the remote
restore branch, and the contract is that the new branch routes through the same
chokepoint** rather than building an argv beside it.

## Quoting

Four nesting levels: `ssh → sh → tmux → sh`. The boundary is provided by
**`remoteQuoted` (`:131-133`)**, *not* by `sanitizeSessionName` (`:97-100`), which folds
only `.`, `:`, space and tab and never touches a quote. Any AC asserting quote/semicolon
neutralisation must target `remoteQuoted`.

## Emitted argvs (must pass)

| Purpose | argv |
|---------|------|
| Card (US-004, DD-002 final shape) | `ssh <dest> "tmux new-session -A -s <name> 'tmux set-environment GHOSTLING_CARD_ID <uuid>; GHOSTLING_CARD_ID=<uuid> exec $SHELL -il'"` |
| Relay (US-003, DD-001) | `ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 <dest> 'tail -n 200 -F ~/.ghostling/events.jsonl'` |
| Install (US-005) | `ssh <dest> 'cat > ~/.claude/ghostling-forward.sh'` with the script bytes piped on **stdin** |
| Probe (US-005) | `ssh <dest> 'cat ~/.ghostling/... 2>/dev/null'` — **no `-t`** |

### The byte-exactness constraint (probe **and** install)

[remote-host-state.md](remote-host-state.md) makes `staleVersion` a **SHA-256 of the script
bytes**. That promotes "the remote file's bytes equal ours" from invisible to permanently
visible on the card, so both channels that carry those bytes are now correctness-critical —
and the constraint belongs here, in the file an implementer reads before writing an emitter,
not only in the file that motivates it.

- **Neither channel may allocate a PTY.** A PTY rewrites LF → CRLF, every byte after the
  first newline shifts, and every host reads `hooks outdated` forever. The trap is concrete:
  `argv(for:)` hardcodes `-t` (`:109`), so `probeArgv`/`installArgv` inheriting the obvious
  pattern ships the bug.
- **Install transfers bytes verbatim — piped on stdin, never interpolated into a remote
  shell word.** `forwarderScript` (`:107+`) contains `$HOME`, `$GHOSTLING_CARD_ID`, `$file`
  and `$@`; an unquoted heredoc expands them **on the far side**, so the installed file
  differs from ours and the hash reports `staleVersion` permanently. Same failure as the
  CRLF one, through the other door.

This resembles the `port`/`identityFile` constraint below: safe by **emission property**,
not by field type, and reopened by any refactor that looks harmless.

Both halves of the card command are required. `set-environment` binds **later** panes
(`Ctrl-b c`); the launch command binds only the first shell's process env.
`set-environment` has no meaningful version floor (tmux 1.0), whereas `new-session -e`
needs tmux ≥ 3.2 — Ubuntu 20.04 ships 3.0a and Debian 11 ships 3.1c, so under "remote OS:
both/varies" it is not a safe foundation.

## Known Constraints

- **`port` / `identityFile` are safe by emission order, not by field property.** Both are
  positionally consumed by a preceding `-p` / `-i` (`:109-112`), so ssh binds them as
  flag arguments rather than parsing them as options. Any refactor that emits one without
  its flag reopens the hole. Record as a constraint on the emitter.
- **A human typing `claude -p` in their own remote pane is not prevented, and nothing
  should try.** The invariant protects the operator from *our* automation.

## Related

- **Stories:** US-001 (owns), US-003, US-004, US-005, US-006
- **Decisions:** DD-004 (owns), DD-002, DD-003 (hard-depends)
