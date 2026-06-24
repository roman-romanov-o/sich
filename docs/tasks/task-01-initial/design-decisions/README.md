# Design Decisions

Architectural decisions and their rationale (ADR format).

> **Mode note:** This task is in **Minimal** mode, where `/saha:decide` is normally skipped. DD-001 is recorded anyway because it reverses a founding constraint (the Terminal "don't replace Ghostty" rule) and is load-bearing for everything downstream.

## Contents

| ID | Title | Status | Date |
|----|-------|--------|------|
| DD-001 | Terminal Substrate — Embed libghostty (Become the Terminal) | Accepted | 2026-06-15 |

## Decision Log

### Accepted
- **DD-001: Terminal Substrate — Embed libghostty.** The app becomes a terminal emulator built on `libghostty` (cmux model, Swift/AppKit, macOS-first). Chosen over coexist-watcher (can't render a live in-app terminal) and ride-cmux (cedes terminal control, no event API yet). Reverses "don't replace Ghostty"; keeps the never-auto-`claude -p` pool discipline. Accepts maintaining a terminal on a pre-stable embedding API.

### Proposed
_None_

### Deprecated
_None_

## Pending sub-decisions (spawned by DD-001)
- DD-002 (TBD): Hybrid (also observe external Ghostty.app) vs. in-app-only.
- DD-003 (TBD): Cross-platform stance (macOS-only v1 vs. cross-platform from the start).
- DD-004 (**Resolved 2026-06-17, file pending**): Board topology — resolved toward **state-columns × two-flow swimlanes** (not "columns *vs.* swimlanes" — *both*) by the HELM UI POC (`research/UI_POC.html`, critique `research/14-ui-mockup-critique.md`). The saha pipeline is an Altitude-1 drill-in, not a board column. Formalize as a `DD-004-*.md` file when convenient.
