<p align="center">
  <img src="assets/sich-icon.png" width="120" alt="Sich icon">
</p>

<h1 align="center">Sich</h1>

<p align="center"><strong>Mission control for parallel agentic coding sessions</strong></p>

Sich is a native macOS app for running many coding agents (Claude Code, Codex,
Gemini CLI) at once without losing track of them. It is a kanban board where
every card **is** a live terminal session — Sich embeds
[libghostty](https://ghostty.org) and becomes the terminal, so it reads agent
state first-hand instead of scraping someone else's window.

## What it does

- **Board of live sessions** — cards move between columns (working / waiting on
  you / done) driven by real agent lifecycle hooks, not heuristics. A "who
  needs me" count surfaces the sessions blocked on your input.
- **Embedded terminal** — click a card to drill into its session: a real PTY
  rendered by libghostty-vt in-process. Scrollback, paste, themes, resize.
- **Quota-aware capacity** — live gauges for the two Anthropic pools
  (interactive subscription vs. API credits), plus Codex/Gemini, so you know
  how much agent capacity you actually have before starting more work.
- **Pool firewall** — managed sessions are interactive-only by construction;
  Sich structurally refuses to spawn headless `claude -p` and spend API credits
  on your behalf.
- **Planning Mode** — drive Sahaidachny (the plan-then-execute agent pipeline
  bundled as slash-commands in [`.claude/`](.claude)) from inside the app:
  stepper, terminal, and rendered planning documents side by side.
- **Per-turn diffs** — review what an agent changed after each turn, as native
  word-level diffs.
- **Remote sessions** — attach tmux sessions on remote boxes over SSH as
  first-class cards.

## Install

Download the latest `Sich.app` from
[**Releases**](https://github.com/roman-romanov-o/agentic-coding-kanban/releases)
— the app ships as a release artifact, never as a binary in this repository.

The bundle is currently unsigned; on first launch either right-click →
**Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/Sich.app
```

Requires macOS 14 or later; the prebuilt app is Apple silicon.

## Build from source

The one non-obvious prerequisite is the vendored **libghostty-vt** static
archives, which are too large to track in git. Rebuild them once (pinned
ghostty rev, Zig **0.15.2** — not Homebrew's 0.16.0) following
[`app/Frameworks/README.md`](app/Frameworks/README.md), then:

```bash
cd app
./make-app.sh            # → build/Sich.app
./make-app.sh --install  # …and copy to /Applications
```

## Develop

```bash
cd app
swift build
swift test        # full suite
swift run sich    # run the board from source
./dev.sh          # DEBUG hot reload via InjectionIII
```

A small residue of repo-level Python tests runs with `uv sync --extra dev &&
uv run pytest`.

## Learn more

- [`docs/PRODUCT.md`](docs/PRODUCT.md) — product thesis and constraints
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the pieces fit
- [`app/README.md`](app/README.md) — Swift package layout and dev workflow
- [`docs/tasks/`](docs/tasks) — the Sahaidachny task plans this app was built from

## License

[MIT](LICENSE)
