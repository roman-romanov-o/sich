# E2E Test Spec: Real Linux Host Sign-Off

**Related Stories:** US-002, US-003, US-004, US-005
**Priority:** Critical
**Status:** Draft
**Suite:** none — **this spec is deliberately not automatable**

## Overview

The one test that actually crosses the network hop, onto a real Linux box, over real ssh,
into a real tmux. It is performed by a human and recorded with a date.

## Why this is a human test and not a CI job

Not a preference — a verified constraint:

- `tmux` is **not installed** on this machine, and `sshd` is **not listening** on it.
- CI is `runs-on: [self-hosted, macOS]` — **this same machine**. Hosted macOS runners
  cannot link the vendored libghostty archives (git-ignored, ~30M) and bill 10× on a
  private repo.
- A second machine is not available to any runner this repo has.

**A loopback ssh test would also be the wrong test.** The failures this covers are
*userland* failures — GNU vs BSD `base64` wrapping, absent `plutil`, tmux version floors —
and ssh-ing to the same macOS box exercises **BSD userland against BSD userland**, which
is the configuration already known to work. It would be green, fast, and blind to every
bug in scope. The name would carry more confidence than the test.

US-002 AC-2 established this precedent: **an AC that is never auto-passable**. It cannot be
satisfied by a checkmark, cannot drift green, and the DoD gate must classify it
`needs_human_signoff` rather than pass it.

## Preconditions

- A real Linux host reachable over Tailscale, with tmux and Claude Code installed.
- The host's tmux version recorded (the `-e` floor is 3.2; Ubuntu 20.04 ships 3.0a).

## Test Cases

### TC-E2E-017: Turn diffs arrive from a Linux host (US-002 AC-2)

**Steps:**
1. Install hooks remotely from the app.
2. Create a remote card; run a real Claude turn on the box that edits a file.
3. Open drill-in.

**Expected Results:**
- The diff renders, correctly, from GNU userland — where `plutil` does not exist and
  `base64` wraps at 76 columns.
- The card moves running → waiting.

**Record:** date, host OS + version, tmux version, verdict, in this file's sign-off log.

---

### TC-E2E-018: A second pane created by hand is bound (US-004 AC-2, on real tmux)

**Steps:** in the card's tmux session, press `Ctrl-b c`; run Claude in the new pane.

**Expected Results:** the card moves. This is the load-bearing half — see
[integration/tmux-env-binding.md](../integration/tmux-env-binding.md), which covers the
same mechanism on **local** tmux with no network at all, and can therefore be automated
once tmux is installed. This case exists to confirm the automated one is not lying about
a real remote server.

---

### TC-E2E-019: The install probe reads `installed` over a real PTY-free channel (US-005)

**Expected Results:** a freshly-installed real host reads `installed`, not
`staleVersion`. This is the case that goes red against a `-t` probe (PTY LF→CRLF
translation shifts every byte after the first newline) and green without it — the only
reason the assertion is worth making.

---

### TC-E2E-021: A network partition reaches `unreachable` via keepalive (US-007 AC-2)

**Description:** Without this case, **the keepalive mechanism is never exercised by any
test in this task.** TC-INT-004 asserts the argv *carries*
`ServerAliveInterval=15`/`ServerAliveCountMax=3` and drives the timeout source explicitly —
it never proves ssh honours them, because ssh is substituted away. Options in an argv are a
claim about ssh's behaviour, not a demonstration of it.

That gap matters because the partition is the *common* case, not the exotic one: a laptop
sleeps or leaves Tailscale's reach far more often than an ssh process cleanly exits. The
fast path TC-E2E-005 covers is the rarer one.

**Steps:**
1. Remote card running, card reads `running`.
2. Partition the host **without** letting ssh exit cleanly — drop Tailscale on the laptop,
   or close the lid. Do not kill the ssh process; that is TC-E2E-005's path and it proves
   nothing here.
3. Watch the card, with a clock.

**Expected Results:**
- The card reaches `unreachable` in **~45s** (15 × 3), and never later than 60s.
- It does **not** sit on `running` indefinitely. A frozen `running` card is the failure this
  AC exists to prevent — the operator reads it as "the agent is working" and waits.

**Record:** date, how the partition was staged, measured seconds to `unreachable`.

## Sign-Off Log

| Date | Host OS | tmux | Cases | Verdict | By |
|------|---------|------|-------|---------|-----|
| _pending_ | | | | | |

**An empty log is a failing gate, not a pending nicety.** No row ⇒ the ssh hop has never
been exercised, and every automated spec in this task stops short of it by construction.
