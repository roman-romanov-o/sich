# Test Coverage Matrix

Every story maps to at least one E2E case. **The "E2E Gap Reason" column is used honestly
here:** no story is E2E-free, but every automated E2E in this task stops short of the ssh
hop, and that shortfall is stated per row rather than hidden behind the word "E2E."

| Story | E2E | Integration | Unit | E2E Gap Reason |
|-------|-----|-------------|------|----------------|
| US-001 ssh can't smuggle headless work | TC-E2E-011 (restore path) | TC-INT-018 | TC-UNIT-001..007 | argv construction is pure; the E2E case covers the one call site that runs with **no human present**. The remaining ACs are total functions over strings — an E2E would assert less, more slowly. |
| US-002 turn diffs from Linux | **TC-E2E-017 (human)** | TC-INT-017 | — | **No Linux host on any runner.** The GNU-userland fixture is automated; the real box is human sign-off, per US-002 AC-2's never-auto-passable precedent. |
| US-003 relay reaches the laptop | TC-E2E-001..004 | TC-INT-001..003, 006, 018 | — | E2E substitutes a local child at the `relayArgv` seam. **The ssh hop itself is TC-E2E-017.** |
| US-004 state lands on the right card | TC-E2E-001, 003; **TC-E2E-018 (human)** | TC-INT-007..011 | — | AC-2 (the load-bearing later pane) needs **real tmux**, which is network-independent — so it is automated locally at integration, and confirmed against a real remote server by human sign-off. |
| US-005 remote hook install | TC-E2E-016 (chip); **TC-E2E-019 (human)** | TC-INT-012..016, 018 | — | Install/probe file semantics are real; the PTY-translation failure only manifests over real ssh, hence the human case. |
| US-006 a remote card survives restart | TC-E2E-007..011 | — | (persisted shape asserted in TC-E2E-008) | Full coverage minus the hop. Persistence, decode, argv rebuild and firewall are all real. |
| US-007 dead connection | TC-E2E-005 (fast path), **TC-E2E-020 (renders)**, **TC-E2E-021 (human, partition)** | TC-INT-004 (keepalive argv) | — | The fast path is automated. **The keepalive is only argv-deep in automation** — ssh is substituted, so nothing proves ssh honours `ServerAlive*`; the partition is human-signed (TC-E2E-021). AC-4 needs its own case because `unreachable` reaching the *model* and reaching the *screen* are different claims. |
| US-008 reconnect doesn't duplicate | TC-E2E-006 | TC-INT-003, 005 | TC-UNIT-008..011 | Keys are pure functions of bytes; the **behaviour** they protect (a reconnect must not move a card backwards) is asserted at E2E. |
| US-009 create palette | TC-E2E-012..015 | — | — | Full coverage. Real `NSEvent` dispatch throughout. |

## Three deliberate departures from the skill's defaults

**1. Unit tests carry US-001, and that is not a gap.** The rule of thumb says unit-only
coverage is a red flag because unit tests usually assert glue. These assert the product's
one economic invariant — never spend the API-credit pool — at the only place it can be
enforced, against **a live hole reachable from ⌘⇧R today**. TC-UNIT-004 in particular
distinguishes the correct guard from the plausible wrong one, which no E2E would catch:
both guards produce a running ssh.

**2. Zero mocks anywhere.** The "5+ mocks ⇒ make it integration" heuristic never triggers
because the substitution is a **real child process at an argv seam**, not a mock object.
Real files, real `tail -F`, real exit codes, real tmux.

**3. Four E2E cases are human-performed and cannot be auto-passed** (TC-E2E-017, 018, 019,
021). Verified, not assumed:
`tmux` is not installed, `sshd` is not listening, and CI (`runs-on: [self-hosted, macOS]`)
is **this same machine** — hosted macOS can't link the git-ignored libghostty archives and
bills 10× on a private repo. A loopback-ssh test would exercise **BSD userland against BSD
userland**, blind to every failure in scope (absent `plutil`, GNU `base64` wrapping, tmux
version floors) — green, fast, and meaningless. Naming it "E2E remote" would be the exact
class of lie this task keeps catching.

## The one new tool dependency

**`brew install tmux`** — required for TC-INT-007..011, and absent today. It buys the only
automated coverage of US-004 AC-2, the mechanism most likely to be silently wrong. Those
tests must **skip loudly** when tmux is missing; a skipped test reporting green is the
failure mode this task documents repeatedly.

## Bindings the DoD gate must respect

- **TC-E2E-017/018/019/021 are `needs_human_signoff`**, never auto-passed. An empty sign-off
  log is a failing gate, not a pending nicety.
- **TC-E2E-020 renders `unreachable`, so it inherits the render-path rules**: real state on
  a layer-backed custom-drawn surface; `cacheDisplay`/`CALayer.render` are non-evidence.
  `unreachable` does not exist in `app/Sources/` today — the state must be *built*, not
  merely asserted.
- **TC-E2E-016's surface (a host chip on `SessionCard`) is my proposal, not the user's** —
  as is accepting bracketed IPv6 in TC-UNIT-005's table. Both are flagged for
  confirmation at `/saha:plan`; if either changes, its spec changes with it.
- **The rule: line numbers only for committed files; everything else by symbol.** 10 of the
  14 files these specs reference are uncommitted, so their numbers decay faster than the
  specs quoting them.

  **This bullet has now been wrong twice, in two different ways, and the second time was in
  the act of fixing the first.** It first asserted the discipline while violating it (three
  decayed citations, and `SignalEvent.swift` named as committed when it isn't). The
  correction then enumerated "the four committed files" — an enumeration that was itself
  wrong in both directions: it listed `DiffModel.swift`, which no spec cites by line, and
  omitted `ghostling-probe/main.swift:25`, which one does.

  **That is four instances in this task of a thoroughness claim decaying.** The lesson is
  in the shape, not the diligence: a compliance claim reads as a summary, so it is the
  least-checked line in any document, and an enumeration is just more surface to rot. State
  the rule; let the specs be checked against it. There is deliberately no file list here.
