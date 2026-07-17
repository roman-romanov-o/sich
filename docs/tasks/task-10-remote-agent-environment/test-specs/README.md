# Test Specifications

Test specs for TASK-10a, organized by type.

## Coverage Summary

| Type | Specs | Test Cases | Stories Covered |
|------|-------|------------|-----------------|
| E2E | 4 | 21 | US-001..009 (all) |
| Integration | 3 | 18 | US-002, US-003, US-004, US-005, US-007, US-008 |
| Unit | 2 | 11 | US-001, US-008 |

Three of the 19 E2E cases (TC-E2E-017/018/019) are **human-performed and never
auto-passable**. See [coverage-matrix.md](coverage-matrix.md).

## The shape of testing this task

The honest summary: **a genuine E2E needs a second machine, and no runner this repo has is
one.** `tmux` is not installed, `sshd` is not listening, and CI runs `[self-hosted, macOS]`
— the same Mac. So the automated E2E specs substitute a **real local child process at the
ssh argv seam** and are named for what they are: an E2E of everything except the network
hop. Everything else in them is real — real JSONL bytes, real `tail -F`, real process
exit, real card state.

The hop is covered by human sign-off, following US-002 AC-2's precedent of an AC that
cannot drift green.

Two things fall out of that decomposition and are worth stating up front:

- **tmux is separable from ssh.** US-004 AC-2 — the later `Ctrl-b c` pane, the mechanism
  most likely to be silently wrong — needs real tmux and **no network at all**. It is
  automated locally, which is why `brew install tmux` is this task's one new dependency.
- **argv construction is separable from everything.** Pure functions, no network, and the
  place the watcher-not-spawner invariant is enforced or lost.

## Contents

### E2E Tests
- [remote-session-lands-on-its-card.md](e2e/remote-session-lands-on-its-card.md) — US-003/004/007/008
- [remote-card-survives-restart.md](e2e/remote-card-survives-restart.md) — US-006
- [creating-a-remote-card.md](e2e/creating-a-remote-card.md) — US-009, US-005
- [real-linux-host-signoff.md](e2e/real-linux-host-signoff.md) — the hop, by hand

### Integration Tests
- [relay-transport.md](integration/relay-transport.md) — rotation, absent file, keepalive, memory bound
- [tmux-env-binding.md](integration/tmux-env-binding.md) — real local tmux
- [remote-hook-install-and-probe.md](integration/remote-hook-install-and-probe.md) — bytes + the four states

### Unit Tests
- [ssh-argv-and-firewall.md](unit/ssh-argv-and-firewall.md) — the live `-oProxyCommand` hole
- [dedup-keys.md](unit/dedup-keys.md) — two line kinds, two keys

### Matrix
- [coverage-matrix.md](coverage-matrix.md) — stories → cases, and where each stops
