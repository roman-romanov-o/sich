# Reddit drafts (launch week, PLAN.md 2.3)

Rules gathered 2026-11-10 from search mirrors (Reddit itself was unreachable);
re-check each sidebar before posting. Never post in or reply to anything that
looks Russian. Space the posts over 2 to 3 days.

| Sub | Where | Gate |
|-----|-------|------|
| r/ClaudeCode | feed | no published rules found |
| r/ClaudeAI | feed if total karma >= 50, else the "Built with Claude" showcase megathread | Rule 7 |
| r/macapps | "The App Pile" monthly megathread, or feed via the transparency path (real identity, e.g. LinkedIn) | one app post per 30 days; Problem / Compare / Pricing / Changelog / AI disclaimer format |

Attach `assets/hero.gif` (or `assets/promo.mp4`) to each post.

## r/ClaudeCode

Title: `Made a macOS kanban where every card is a live Claude Code terminal`

```
Was running 5+ Claude Code sessions and kept missing the one waiting on me.

So I built a board. Each card is a real terminal (libghostty). Claude Code hooks move the cards: working, needs you, done.

- ⌃Tab jumps to whoever is waiting
- quota gauges: subscription, API credit, Codex
- never runs claude -p, so no surprise API bill
- tmux sessions over SSH show up as cards
- pomodoro holds agent questions until your break

Free, MIT, native Swift, signed DMG.
https://github.com/roman-romanov-o/sich

Built it with Claude Code. Bug reports welcome.
```

## r/ClaudeAI (showcase megathread comment if under 50 karma)

```
Sich: macOS kanban for Claude Code. Every card is a live terminal, hooks move it to "needs you" when Claude asks something. Quota gauges for subscription and API credit. Never spawns claude -p.

Free, MIT. https://github.com/roman-romanov-o/sich
```

## r/macapps (App Pile comment, their required format)

```
Sich: kanban board where every card is a live Claude Code / Codex terminal
https://github.com/roman-romanov-o/sich

Problem: 5 coding agents in 5 terminal tabs, no idea which one is waiting on me.
Compare: closest are Vibe Kanban and Conductor. Sich is native AppKit, hosts the real terminal sessions, and shows quota gauges.
Pricing: free, MIT, no account.
Changelog: v0.4.0 signed + notarized DMG, Homebrew cask.
AI disclaimer: built with Claude Code, reviewed by me.

macOS 14+, Apple silicon and Intel.
```
