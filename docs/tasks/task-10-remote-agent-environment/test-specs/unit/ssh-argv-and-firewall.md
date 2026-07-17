# Unit Test Spec: ssh argv Construction + PoolFirewall

**File:** `app/Sources/GhostlingCore/RemoteTmuxCommand.swift`, `app/Sources/GhostlingCore/PoolFirewall.swift`
**Related:** US-001, [DD-004](../../design-decisions/DD-004-poolfirewall-ssh-command-inspection.md)
**Priority:** Critical
**Status:** Draft
**Suite:** `app/Tests/GhostlingCoreTests/RemoteTmuxCommandTests.swift`, `PoolFirewallTests.swift` (both exist)

## Overview

Unit tests, and **unjustified only if you think this is glue**. It is not: argv
construction is pure, total, and the place where the product's one economic invariant is
either enforced or lost. `PoolFirewall` describes itself in-code as **structural, not
advisory**.

**This closes a live hole in shipped code, reachable from ⌘⇧R today.** Not a hypothetical
hardening pass.

## The hole

`-oProxyCommand=sh -c 'claude -p x'` has **no `@` and no trailing `:<int>`**, so it
survives `parse()` whole and reaches `argv.append(target)` (`:116`) — **in ssh's option
position**.

That position is the point: **ssh options execute locally.** The payload never crosses the
network. `PoolFirewall` sees `/usr/bin/ssh` — not `claude` — and `isClaude` compares
`lastPathComponent == "claude"` (`:49-51`), so it waves the argv through and the app
launches headless `claude -p` against the **API-credit pool** the entire product exists to
avoid touching. The destination position is strictly more dangerous than the remote-command
position, which is the opposite of the intuition.

## Test Cases

### TC-UNIT-001: The firewall inspects ssh remote commands (US-001 AC-1)

**Input:** `PoolFirewall.classify(["/usr/bin/ssh", "host", "claude -p 'x'"])`
**Expected:** throws.

**Notes: red first.** `classify` gates `assertNoHeadlessFlag` behind `isClaude(argv.first)`
(`:41-51`), and `isClaude("/usr/bin/ssh")` is false — so this argv returns `.interactive`
**uninspected** and the case throws nothing today. DD-004 owns closing it with a best-effort
scan of the remote-command token.

**Read "the input passes today" as the hole, not as the test passing.** An earlier draft of
this note said the opposite — that `PoolFirewall` already closes the remote-command
position, so the case was a green-on-arrival regression guard. That was false against
`classify`, and it contradicted this file's own **The hole** section fifteen lines above,
which says `PoolFirewall` sees `/usr/bin/ssh` and waves the argv through. An implementer
who believed it would skip DD-004's scan and ship the constraint unenforced.

**The contrast with TC-UNIT-002 survives, and is sharper than the wrong version claimed:**
both are red today, and they close under **different mechanisms** — the token scan here,
the destination grammar there. Not "one of the two is caught."

---

### TC-UNIT-002: `-oProxyCommand=` in the destination is refused (US-001 AC-2)

**Input:** `argv(for: spec)` where `host` is `-oProxyCommand=sh -c 'claude -p x'`
**Expected:** throws `invalidDestination`.

---

### TC-UNIT-003: The user position is equally guarded (US-001 AC-3)

**Input:** `user = "-oProxyCommand=…"`, any host
**Expected:** throws.
**Notes:** `target = "\(user)@\(host)"` (`:114-115`) — `user` is equally unguarded. The
guard belongs on the **composed destination**, not on `host` alone.

---

### TC-UNIT-004: A directly-built spec with leading whitespace is refused (US-001 AC-4)

**Input:** `RemoteTmuxSpec(host: " -oProxyCommand=sh -c 'claude -p x'", …)` — built
**directly**, not through `parse()`.

**Expected:** throws.

**Notes: this is the case that distinguishes the correct guard from the plausible wrong
one, and it is the most valuable test in this task.** The `target` property (`:36-40`)
composes the **untrimmed** host, while the token actually appended at `:116` is rebuilt
from the **trimmed** host (`:104`). A guard on `spec.target` **passes this input** — it
starts with a space, not `-` — and ssh then receives the trimmed option anyway.

**Validate post-trim, on the exact string appended.** And note why `parse()` cannot be the
guard: a spec built directly never passes through it. That coverage gap — not the edit
count — is why `parse()` keeps its Optional return rather than becoming throwing.

---

### TC-UNIT-005: Legitimate argvs still pass (US-001 AC-5)

**Expected:** the relay argv, the install/probe argvs, and DD-002's **final** tmux shape
all classify clean.

**Notes:** the tmux command nests **four quoting levels** (`ssh → sh → tmux → sh`). Assert
the *final* shape — an assertion against an intermediate is an assertion against a string
that never reaches ssh.

---

### TC-UNIT-006: Quoting is asserted against the function that provides it (US-001 AC-6)

**Input:** a session name / remote dir containing `'` or `;`
**Expected:** neutralised by **`remoteQuoted` (`:131-133`)**.

**Notes:** **not** by `sanitizeSessionName` (`:97-100`), which folds only `.`, `:`, space
and tab and never touches a quote. Asserting the sanitizer here would be asserting the
wrong function and would pass while the real defense rotted.

`remoteQuoted` is **`private static`** — the test cannot call it. Assert its effect in
`argv(for:)`'s output, which is the right level anyway: what ships is the argv, and a
`fileprivate`-widening or `@testable` reach-in would bind the test to a function the
product could stop calling while the test stayed green.

---

### TC-UNIT-007: `-p` / `-i` emission order is a constraint (US-001 edge case)

**Expected:** `port` and `identity` are emitted **immediately after their flags**
(`:109-112`).

**Notes:** dash-leading values there are harmless **today** only because ssh binds them
positionally as flag arguments. Record this as a constraint on **emission order**, not as
a property of the fields — any refactor that emits one without its flag reopens the hole.
This test exists to fail that refactor.

## Parameterized Cases

| `host` input | Expected | Why |
|---|---|---|
| `boxA` | passes | baseline |
| `-oProxyCommand=sh -c 'claude -p x'` | throws | local execution |
| `" -oProxyCommand=…"` (leading space) | throws | **post-trim guard** |
| `--` | throws | ends option parsing; dash-leading |
| `[fe80::1]` | passes | bracketed IPv6 — ⚠️ **my decision, not the user's**; flagged for `/saha:plan` |

## Mocks Required

**None.** These are pure functions over strings. If a mock appears here, the test has
drifted into integration and belongs elsewhere.
