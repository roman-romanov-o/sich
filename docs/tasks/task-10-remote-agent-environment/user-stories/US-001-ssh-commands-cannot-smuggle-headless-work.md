# US-001: ssh Commands Cannot Smuggle Headless Work

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator (the developer running agents on the board)
**Estimated Complexity:** M

## User Story

As an **operator**,
I want to **be sure ghostling can never spawn headless agent work on my behalf, on any machine, even when the command it runs is `ssh`**,
So that **my interactive subscription is never silently billed against the separate API-credit pool — the economic invariant the whole product rests on**.

## Acceptance Criteria

- [ ] **AC-1:** `PoolFirewall.classify(["/usr/bin/ssh", "host", "claude -p 'x'"])` throws. Today it returns `.interactive` uninspected, because `classify` gates `assertNoHeadlessFlag` behind `isClaude(argv.first)` (`PoolFirewall.swift:41-51`) and `"ssh"` is not `"claude"`. Written red first.
- [ ] **AC-2:** A destination that is really an ssh **option** is refused at **argv construction**: `RemoteTmuxCommand.argv(for:)` throws `RemoteTmuxCommand.Invalid.invalidDestination` for a spec whose destination resolves to `-oProxyCommand=sh -c 'claude -p x'` — whether that spec was produced by `parse()` or built directly. This is a **live hole in shipped code**: such a destination has no `@` and no trailing `:<int>`, so it survives `parse()` whole, reaches `argv.append(target)` (`RemoteTmuxCommand.swift:116`) in ssh's option position, and ssh executes ProxyCommand **on the local machine**. Written red first; it passes trivially today only because nothing throws.
  **`parse()` keeps its Optional return and does not become throwing.** It is `public static func parse(...) -> RemoteTmuxSpec?` (`:46`); making it throw would change **7** call sites including `BoardShell.promptRemoteTmux`, and **2** assertions of `== nil` (both inside the single test `parseRejectsHostless`, `RemoteTmuxCommandTests.swift:98-99`) — but the reason to keep it Optional is the coverage gap AC-4 proves, not the edit count: a spec built directly never passes through `parse`. `Invalid` is nested on `RemoteTmuxCommand` (`:82`), not on `RemoteTmuxSpec`. `parse()` may *additionally* reject such a destination by returning `nil` — a UI nicety, not the guarantee.
- [ ] **AC-3:** The same refusal holds when the payload rides the **user** position (`-oProxyCommand=…@host`), because `target = "\(user)@\(host)"` (`:114-115`) and `user` is equally unguarded. The guard is on the composed destination, not on `host` alone.
- [ ] **AC-4:** A `RemoteTmuxSpec` built **directly** — not through `parse()` — with `host: " -oProxyCommand=…"` (**leading whitespace**) also throws. This is the acceptance criterion that distinguishes the correct guard from the plausible wrong one: the `target` property (`:36-40`) composes the **untrimmed** host, while the token actually appended at `:116` is rebuilt from the **trimmed** host (`:104`). A guard on `spec.target` passes this input — it starts with a space, not `-` — and then ssh receives the trimmed option anyway. Validate **post-trim**, on the exact string appended.
- [ ] **AC-5:** The argvs this task legitimately emits **pass**: DD-001's `ssh … tail -F …` relay and DD-002's `tmux new-session …` command, the latter asserted against DD-002's *final* command shape (which prepends `tmux set-environment`), not today's.
- [ ] **AC-6:** The quoting boundary is asserted against the function that actually provides it: a session name or remote dir containing `'` or `;` is neutralised by `remoteQuoted` (`:131-133`), **not** by `sanitizeSessionName` (`:97-100`), which folds only `.`, `:`, space and tab and never touches a quote.

## Edge Cases

1. **A legitimate session name contains the substring `claude`**
   - Trigger: `tmux new-session -A -s claude-work`.
   - Expected behavior: passes. The scan must not be implemented as a substring search for `claude` over the joined argv.

2. **`port` / `identityFile` carry a dash-leading value**
   - Trigger: a snapshot or caller supplying `identityFile: "-oProxyCommand=…"`.
   - Expected behavior: harmless **today**, because both are positionally consumed by a preceding `-p` / `-i` flag (`:109-112`), so ssh binds them as flag arguments rather than parsing them as options. Record this as a constraint on **emission order**, not as a property of the fields: any refactor that emits one of these values without its flag reopens the hole.

3. **A user runs `claude -p` themselves inside their own remote tmux pane**
   - Trigger: the human types it.
   - Expected behavior: nothing here prevents it, and nothing should try. The invariant protects the operator from *our* automation, not from themselves on their own box.

## Technical Notes

The framing that makes this tractable (DD-004): "make `claude -p` impossible on a remote host" is **not achievable** — it is a string parsed by a shell we do not control, and `cl''aude -p`, aliases and wrappers defeat any scan. The achievable goal is "**ghostling** never spawns headless work."

So the guarantee is **structural**: ssh argvs may only be *generated* from constrained specs, never supplied. A token scan rides underneath, labelled explicitly best-effort — a scan that *looks* sound is a liability; labelled honestly, it is a net.

Also delete the dead store at `RemoteTmuxCommand.swift:114` (`var target = spec.target`, immediately overwritten), which is what made the untrimmed/trimmed divergence easy to miss in the first place.

**This story ships first**, before the three new ssh-emitting call sites exist. Retrofitting a firewall around code written without it is how the firewall ends up shaped like the thing it was supposed to constrain.

## Dependencies

- **Requires:** nothing.
- **Enables:** US-003 (tail relay), US-005 (`installRemote`), US-006 (restore rebuilds an argv from disk with no human present — the sharpest of the three).

## Execution History

| Iteration | Phase | Result | Notes |
|-----------|-------|--------|-------|
| - | - | - | Not yet executed |

## Questions

- [ ] Does the destination grammar admit IPv6 literals (`[::1]`, `user@[fe80::1%en0]`)? Tailscale hands out IPv6 addresses, so a grammar that only accepts `[A-Za-z0-9.-]` would refuse a real host. Resolve before implementing the check.

## Related

- Task: [task-description.md](../task-description.md) — the `PoolFirewall` row in Constraints
- Design Decision: [DD-004](../design-decisions/DD-004-poolfirewall-ssh-command-inspection.md) (owns this), [DD-003](../design-decisions/DD-003-location-model-and-remote-restore.md) (hard-depends on it)
