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

## Using saha from the board (Planning Mode)

The board is the cockpit for **saha** (Sahaidachny, the agentic planning + execution
loop) — you drive a task from a blank folder to a verified implementation without
leaving the app. Two flows, one board:
**Flow-A / saha** (the planning + `/saha:execute` loop) and **Flow-B / interactive**.

**1. Create a saha task card.** Click **+** on the board to open the **New task**
dialog, name the work, pick the project folder, then press **“Plan with saha…”**
(the other button, “Interactive terminal”, makes a plain login-shell card instead).
A saha chooser then appears:

- **Create new** — runs `.claude/scripts/init_task.sh` to scaffold a fresh
  `docs/tasks/task-NN-<slug>/` folder (auto-numbered) and binds the card to it.
- **Pick an existing folder** — binds the card to a task folder you already have.

The card records its task folder; creating a second card never re-points the first
(each binding is independent). A bare folder with no `README` shows an **"unknown"**
progress chip rather than crashing.

**2. Planning Mode opens automatically.** Creating (or picking) the task drops you
straight into the *planning altitude* — a full-window, three-pane overlay (click the
card on the board to return to it later):

| Pane | What it shows |
|------|----------------|
| **Stepper** (left) | the 8-step saha pipeline with each step's live state (done / next / pending / unknown) |
| **Terminal** (center) | the card's own embedded session — the *same* PTY, mounted once, never a second spawn |
| **Document** (right) | the natively-rendered markdown for the selected step (GFM tables, task lists, headers, Mermaid when `mmdc` is present) |

**3. Walk the pipeline.** Click a step to load its document. For the **next-incomplete**
step, the click also *pre-types* — but does not send — its slash command into the terminal,
so you review and press ⏎ yourself:

| Step | Command | Step | Command |
|------|---------|------|---------|
| Research | `/saha:research` | Code changes | `/saha:contracts` |
| Task description | `/saha:task` | Test specs | `/saha:test-specs` |
| User stories | `/saha:stories` | Implementation plan | `/saha:plan` |
| Design decisions | `/saha:decide` | Verify | `/saha:verify` |

Clicking a **done** step just opens its document (no re-typing); once the pipeline is
planned, run `/saha:execute` in the same terminal to launch the execution loop. Return
to the board with **⌘[** (or the back affordance) — the planning session stays registered
and running.

**Where the step state comes from.** The stepper prefers `saha plan-status --json` when
that command exists, and **silently falls back** to scraping the task README's status
markers otherwise — so it works with or without the saha CLI installed. External edits to
the task folder refresh the stepper live via a file watcher.

Everything runs through the **pool firewall**: the planning terminal is a normal
interactive session and can never become a headless `claude -p` spend.

## Status

The Python sidecar is built and green. The **Phase 00 libghostty embedding spike passed (GO)**
on 2026-06-16 — embedding libghostty-vt + reading a child's PTY in-process is proven (see
`spike/phase00-pty-smoke/`). **Phase 01 (Terminal Foundation) is under way:** the Swift package
in `app/` vendors `ghostty-vt.xcframework`, does the in-app in-process PTY read in Swift, and
enforces the interactive-vs-headless pool firewall in code — `cd app && swift test` is green
(8 tests). Remaining: the windowed AppKit terminal *surface* and the board UI. Building the
xcframework needs Ninja + **Zig 0.15.2** (not Homebrew's 0.16.0). See
`docs/tasks/task-01-initial/STATUS.md` and `app/README.md` for the full breakdown.
