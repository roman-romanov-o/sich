# Integration Test Specs

Where E2E can't reach reliably: rotation, timing, an absent file, memory bounds, and the
real-tmux mechanism that is network-independent.

| Spec | Stories | Cases | Needs |
|------|---------|-------|-------|
| [relay-transport.md](relay-transport.md) | US-003, 007, 008 | TC-INT-001..006 | a real child process, a temp dir |
| [tmux-env-binding.md](tmux-env-binding.md) | US-004 | TC-INT-007..011 | **`brew install tmux` — absent today** |
| [remote-hook-install-and-probe.md](remote-hook-install-and-probe.md) | US-005, US-002 | TC-INT-012..018 | a temp dir, a substitute child |

**Zero mocks.** The "5+ mocks ⇒ make it integration" heuristic never fires because the
substitution is a real child process at an argv seam, not a mock object. If a mock appears
in one of these suites, the design drifted.

**tmux tests must skip loudly when tmux is missing.** A skipped test reporting green is
precisely the silent-failure class this task exists to prevent.
