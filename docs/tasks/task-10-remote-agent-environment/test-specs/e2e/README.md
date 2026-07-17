# E2E Test Specs

Full user flows. **Read [../coverage-matrix.md](../coverage-matrix.md) before adding
one:** the automated specs here substitute a real local child process for the ssh hop, and
are named accordingly. Calling such a test "E2E remote" without that qualifier is the
class of lie this task keeps catching — a green whose green means less than its name.

| Spec | Stories | Cases | Automatable |
|------|---------|-------|-------------|
| [remote-session-lands-on-its-card.md](remote-session-lands-on-its-card.md) | US-003, 004, 007, 008 | TC-E2E-001..006, 020 | yes, minus the hop |
| [remote-card-survives-restart.md](remote-card-survives-restart.md) | US-006 | TC-E2E-007..011 | yes, minus the hop |
| [creating-a-remote-card.md](creating-a-remote-card.md) | US-009, US-005 | TC-E2E-012..016 | yes |
| [real-linux-host-signoff.md](real-linux-host-signoff.md) | US-002, 003, 004, 005, 007 | TC-E2E-017..019, 021 | **no — human, by design** |

**The binding rule:** every interaction assertion dispatches a real input event
(`NSEvent`/`keyDown`/a real click), never a direct handler call. Proven red→green. This
has shipped broken three times when a test called the handler instead. And
`cacheDisplay`/`CALayer.render` are **non-evidence** for a visual AC — they don't
faithfully composite stock AppKit control layers.
