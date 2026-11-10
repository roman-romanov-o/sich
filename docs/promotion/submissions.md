# Phase 1 submission drafts

Drafted 2026-11-10 for PLAN.md 1.1–1.5. Re-read each list's CONTRIBUTING right
before sending; submit one list every few days, never in a burst.

## 1.1 awesome-libghostty → *AI Tools & Agent Orchestration*

Commit / PR title: `feat: add Sich`

Entry (alphabetical within the section):

```
- [Sich](https://github.com/roman-romanov-o/sich) - Native macOS kanban board where every card is a live coding-agent terminal rendered with libghostty-vt.
```

PR body (keep it this short, the list closes verbose PRs):

```
Adds Sich, a macOS app that embeds libghostty-vt for its agent terminals.
```

## 1.2 awesome-cli-coding-agents → *Harnesses & orchestration › Session managers & parallel runners*

Entry (star-sorted; fill in the star count on the day):

```
- [Sich](https://github.com/roman-romanov-o/sich) ⭐ N - Native macOS kanban for Claude Code, Codex and other CLI agents. Each card is a real PTY session (libghostty), moved between columns by the agents' lifecycle hooks; remote cards attach tmux over SSH.
```

PR body:

```
Sich hosts CLI coding agents in real PTY sessions and tracks them through the
agents' own CLI hooks (Claude Code, Codex). The terminal is the primary
interface; the board is a view over those sessions.
```

## 1.3 awesome-mac → Developer Tools / Terminal (all four READMEs)

```
- [Sich](https://github.com/roman-romanov-o/sich) - Kanban board where every card is a live Claude Code or Codex terminal. [![Open-Source Software][OSS Icon]](https://github.com/roman-romanov-o/sich) ![Freeware][Freeware Icon]
```

Translate the description for `README-zh.md`, `README-ja.md`, `README-ko.md`.
One entry per PR.

## 1.4 awesome-claude-code (issue web form, filed by hand, no `gh`)

- Name: Sich
- Link: https://github.com/roman-romanov-o/sich
- Category: Tooling / orchestrators
- Description: Native macOS kanban where every card is a live Claude Code
  session, moved by Claude Code hooks, with subscription and API quota gauges.
- License: MIT

## 1.5 AlternativeTo

- Name: Sich · Platform: Mac · License: Open source (MIT) · Free
- Alternative to: Vibe Kanban, cmux, Conductor, Claude Squad
- Short: A native macOS kanban for coding agents where every card is a live
  terminal.
- Long: Sich runs Claude Code, Codex and other CLI agents as real terminal
  sessions on a kanban board. Cards move between Queue, Working, Needs you and
  Done from the agents' own lifecycle hooks; a built-in pomodoro holds agent
  questions while you focus; live quota gauges show your Claude subscription,
  API credit and Codex limits. Remote tmux sessions over SSH appear as cards
  too.
