# Test Specifications

Test specs for task-01 v1 (US-001–006), written **E2E-first**. Every v1 story has E2E coverage; integration covers what E2E can't reliably trigger; unit covers only genuinely tricky pure logic.

## Cross-cutting harness principles

- **Native macOS app (DD-001, Swift/AppKit)** → UI E2E via XCUITest or equivalent. Exact frameworks are an implementation-plan decision; specs are behavior-level.
- **The suite never spends quota and never calls `claude -p`.** A **fake-agent fixture** (scripted process that renders to the PTY and emits real-shaped Claude Code hooks/JSONL) stands in for paid `claude`; quota sources are stubbed with recorded values. This is both cost/flakiness hygiene and the watcher constraint applied to the tests themselves.
- Pytest-form fixtures shown in integration/unit specs follow repo convention; actual harness language follows the stack decision (the quota/state layer may be a separate daemon).

### ⚠️ Phase-0 dependency / harness feasibility (read before estimating)

The entire **E2E layer is gated on DD-001's Phase-0 libghostty embedding spike** — `TC-E2E-101` is that gate, not a peer test. As of 2026-06-15 the libghostty rendering/input/widget layer is "roadmap, not released," so **none of these E2E cases is implementable today**; they are blocked on (a) the Phase-0 spike proving the embedding is stable, and (b) the open stack/platform decisions (DD-002/DD-003). This is expected at planning stage — stated here so it isn't mistaken for ready-to-build.

**If Phase-0 fails → Option-3 fallback (ride cmux's socket).** That re-targets the read-path assertions: `TC-E2E-102`'s "in-process PTY read, not scripting" *inverts* to "read via cmux `surface.read_text` socket." Treat the E2E suite's read-path assertions as coupled to the un-validated Option-2 outcome.

### E2E test-ID namespaces (intentional, non-colliding)

Each E2E spec owns a numeric range so IDs are globally unique:
- `TC-E2E-001..099` → board-situational-awareness (board/state/attention/drill-in)
- `TC-E2E-100..199` → launch-session-embedded-terminal (terminal substrate)
- `TC-E2E-200..299` → two-pool-quota-visibility

## Coverage Summary

| Type | Specs | Test Cases | Stories Covered |
|------|-------|------------|-----------------|
| E2E | 3 | 15 | US-001, US-002, US-003, US-004, US-005, US-006 |
| Integration | 2 | 8 | US-004, US-006 |
| Unit | 2 | ~16 (incl. parameterized) | US-004, US-006 |

## Coverage Matrix (AC-level)

| Story | AC / edge | E2E | Integration | Unit | Gap reason |
|-------|-----------|-----|-------------|------|------------|
| US-001 | AC1 shell renders | TC-E2E-101 | — | — | — |
| US-001 | AC2 direct PTY read | TC-E2E-102 | — | — | — |
| US-001 | AC3 pool firewall | TC-E2E-103 | — | — | — |
| US-001 | edge: libghostty break / crash | TC-E2E-101, 104 | — | — | — |
| US-002 | AC1–3 drill-in + <500ms | TC-E2E-003 | — | — | — |
| US-002 | edge: ended session / 7-session scale | TC-E2E-005, 007 | — | — | — |
| US-003 | AC1–3 cards by state, metadata, live move | TC-E2E-001 | — | — | — |
| US-003 | edge: external session | — | — | — | Out of v1 scope (in-app-only; DD-002 pending) |
| US-003 | edge: stale/zombie card | TC-E2E-006 | — | — | — |
| US-004 | AC1 hook→state | TC-E2E-001 | TC-INT-001 | TC-UNIT-001/002 | — |
| US-004 | AC2 waiting feeds count | TC-E2E-002 | TC-INT-001 | — | — |
| US-004 | AC3 ambiguous→unknown | TC-E2E-004 | TC-INT-003 | TC-UNIT-003 | — |
| US-004 | edge: dropped hook / rapid | — | TC-INT-002, 004 | — | E2E can't reliably drop/race signals → integration |
| US-005 | AC1/AC2 count + navigate | TC-E2E-002 | — | — | — |
| US-005 | AC3 zero / no false alarm | TC-E2E-002 (step 4) | — | — | — |
| US-005 | edge: long-wait age badge | — | — | — | Optional (US-005 marks it optional); deferred, not v1-required |
| US-006 | AC1 both Anthropic pools | TC-E2E-201 | TC-INT-101 | TC-UNIT-101/104 | — |
| US-006 | AC2 Codex/Gemini + unknown | TC-E2E-202 | TC-INT-103 | — | — |
| US-006 | AC3 confidence | TC-E2E-203 | TC-INT-102 | — | — |
| US-006 | edge: exhausted pool | TC-E2E-204 | TC-INT-104 | — | — |

Every v1 story has E2E coverage at the AC level. The two intentionally-untested rows carry explicit gap reasons (out-of-scope external sessions; an optional age-badge behavior). Reliability edges (dropped/raced signals) are deliberately pushed to integration where they can be triggered deterministically.

## Contents

### E2E Tests
- [board-situational-awareness.md](e2e/board-situational-awareness.md) — US-002/003/004/005
- [launch-session-embedded-terminal.md](e2e/launch-session-embedded-terminal.md) — US-001 (incl. Phase-0 smoke + pool-firewall guard)
- [two-pool-quota-visibility.md](e2e/two-pool-quota-visibility.md) — US-006

### Integration Tests
- [agent-state-detection.md](integration/agent-state-detection.md) — US-004 (hook-gap reconciliation, precedence, ambiguity)
- [quota-pool-aggregation.md](integration/quota-pool-aggregation.md) — US-006 (multi-source assembly, confidence, pool independence)

### Unit Tests
- [state-classifier.md](unit/state-classifier.md) — US-004 (pure signal→state mapping)
- [interactive-window-math.md](unit/interactive-window-math.md) — US-006 (5h rolling window + weekly cap)
