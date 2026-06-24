# Agentic Coding Mission Control

Parallel-session mission control + quota-aware capacity planning for agentic coding
(Claude Code, Codex, Gemini CLI). See `docs/tasks/task-01-initial/` for the full plan.

The product is a macOS-native Swift/AppKit app that **embeds libghostty** and becomes the
terminal for managed sessions (see `design-decisions/DD-001`). This repository currently
contains the **Python sidecar** — the headless, quota-safe logic core that the app consumes:

| Module | Backs | Phase / Story |
|--------|-------|---------------|
| `mission_control.detector` | session state detection | Phase 02 / US-004 |
| `mission_control.quota` | two-pool quota model + window math | Phase 04 / US-006 |
| `mission_control.board` | state→column placement, attention count | US-003 / US-005 (pure parts) |

The sidecar **never spawns `claude -p`** and **never spends quota** — tests run entirely
against recorded fixtures and a fake-agent harness.

## Develop

```bash
uv sync --extra dev      # create venv, install deps + dev tools
uv run pytest            # run the test suite
uv run ruff check src tests
uvx ty check src         # type check
uvx complexipy src       # cognitive complexity
```

## Status

The Python sidecar is built and green. The **Phase 00 libghostty embedding spike passed (GO)**
on 2026-06-16 — embedding libghostty-vt + reading a child's PTY in-process is proven (see
`spike/phase00-pty-smoke/`). **Phase 01 (Terminal Foundation) is under way:** the Swift package
in `app/` vendors `ghostty-vt.xcframework`, does the in-app in-process PTY read in Swift, and
enforces the interactive-vs-headless pool firewall in code — `cd app && swift test` is green
(8 tests). Remaining: the windowed AppKit terminal *surface* and the board UI. Building the
xcframework needs Ninja + **Zig 0.15.2** (not Homebrew's 0.16.0). See
`docs/tasks/task-01-initial/STATUS.md` and `app/README.md` for the full breakdown.
