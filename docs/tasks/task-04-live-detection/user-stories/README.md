# User Stories

User stories define features from the operator's perspective. Derived from
`../task-description.md`; each acceptance criterion is written to be testable
and maps to a task success criterion.

## Contents

| ID | Title | Priority | Status | Complexity | Fixes |
|----|-------|----------|--------|-----------|-------|
| US-001 | Event-driven, size-independent board delivery | Must Have | Ready | M | 3s poll, whole-file re-read |
| US-002 | Trustworthy card state (reconciler correctness) | Must Have | Ready | L | dropped hook, wrong multi-session state, inferred attention, 30s decay |
| US-003 | Resume sessions after restart | Should Have | Ready | L | no persistence |
| US-004 | Semantic shell signal (Ghostty shell-integration) | Could Have | Ready | M | inferred cwd |
| US-005 | Board stays live while drilled in | Should Have | Ready | S | drill-in refresh freeze |

## Story Map

### Operator — "the board is trustworthy in real time" (the stated pain)
- US-001: instant, size-independent delivery
- US-002: correct state even with dropped hooks / shared dirs
- US-005: no freeze while drilled in

### Operator — "the surface is durable and rich"
- US-003: restart resume
- US-004: semantic shell signal

## Notes

- **Must-Have core = US-001 + US-002** — these directly resolve "the board
  updates badly." Recommended first phase.
- Cross-cutting DoD (task Success Criterion 8): `swift test` + `pytest` stay
  green and every AC binds to a named test — enforced by the plan/test-specs,
  not a separate story.
- Priorities are drafted (delegated by the operator); adjust in review.
