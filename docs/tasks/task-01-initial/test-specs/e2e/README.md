# End-to-End Tests

Full-flow specs driven via XCUITest (or equivalent) with a **fake-agent fixture** in place of paid `claude` — the suite never spends quota.

## Contents

| Spec | Stories | Priority | Key cases |
|------|---------|----------|-----------|
| [board-situational-awareness.md](board-situational-awareness.md) | US-002/003/004/005 | Critical | cards-by-state, who-needs-me count + zero/quiet state, drill-in, unknown-not-guess, clean-exit, zombie-card-stale, 7-session scale |
| [launch-session-embedded-terminal.md](launch-session-embedded-terminal.md) | US-001 | Critical | Phase-0 embedding smoke, direct PTY read, **pool-firewall guard (no `claude -p`)**, crash surfaced |
| [two-pool-quota-visibility.md](two-pool-quota-visibility.md) | US-006 | High | both Anthropic pools distinct, Codex/Gemini + unknown, confidence, exhausted states |
