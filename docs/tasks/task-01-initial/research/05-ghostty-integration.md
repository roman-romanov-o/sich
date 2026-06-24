# Research: Ghostty Integration Mechanics (April 2026)

**Date:** 2026-04-27
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

On macOS, Ghostty exposes a working AppleScript dictionary that gives an external app full per-tab visibility and focus control (windows -> tabs -> terminals, with `focus`, `select tab`, `activate window`, working-directory queries, `input text`, `send key`, `perform action`). On Linux, the official path is D-Bus; cross-platform Unix-socket IPC has been **explicitly deferred** by the maintainer. There is **no** `ghostty +focus-tab` style CLI control surface today, and the request to open new tabs in an existing instance via CLI was **closed as not planned**. Net: per-tab focus from a sibling app is feasible *on macOS* via AppleScript, but the dashboard cannot rely on a Ghostty-native CLI or socket and there is real upstream signal that Mitchell Hashimoto wants to keep this scoped.

## Key Findings

### 1. AppleScript is the working integration surface on macOS

- **Evidence:** [`ghostty.org/docs/features/applescript`](https://ghostty.org/docs/features/applescript), [`Ghostty.sdef` source](https://github.com/ghostty-org/ghostty/blob/main/macos/Ghostty.sdef).
- **Object model exposed:** `application -> windows -> tabs -> terminals`.
  - Window properties: `id`, `name`, `selected tab`.
  - Tab properties: `id`, `name`, `index`, `selected`, `focused terminal`.
  - Terminal properties: `id`, `name`, `working directory`.
- **Commands available:** `focus`, `select tab`, `activate window`, `new window`, `new tab`, `split`, `close`, `close tab`, `close window`, `input text`, `send key`, `perform action`.
- **Implication:** A dashboard can (a) enumerate every Ghostty tab across windows, (b) read each tab's `working directory` to correlate "this tab = project X", (c) call `select tab` + `activate window` (or `focus`) to bring a specific tab to the foreground. This is the single most important enabling fact for the "click the project, jump to its terminal" workflow.

### 2. There is NO cross-platform Ghostty IPC socket — by design

- **Evidence:** [ghostty-org/ghostty Discussion #2353 — "Scripting API for Ghostty"](https://github.com/ghostty-org/ghostty/discussions/2353).
- Maintainer (mitchellh) outlined the official direction: macOS = AppleScript / App Intents; Linux = D-Bus; cross-platform = deferred.
- A general escape-sequence-driven scripting layer was **shelved due to security concerns**.
- A broad universal API was rejected in favor of "scoped, use-case-specific implementations".
- **Implication:** Anyone wanting "one socket to script Ghostty on Mac and Linux" is going against the grain of upstream. The dashboard either commits to per-platform integration (AppleScript on macOS, D-Bus on Linux) or builds outside Ghostty entirely (e.g., wrap with cmux or use a tmux layer).

### 3. There is NO `ghostty +focus-tab` / `ghostty +new-tab` CLI

- **Evidence:** [Discussion #4579](https://github.com/ghostty-org/ghostty/discussions/4579), [Discussion #3445](https://github.com/ghostty-org/ghostty/discussions/3445), [Issue #12136](https://github.com/ghostty-org/ghostty/issues/12136) — all closed without implementation; #12136 is "closed as not planned".
- Available CLI surface is essentially `ghostty -e <command>` (run command in a new window), and platform-specific helpers like `ghostty +new-window` (Linux D-Bus). On macOS the supported workaround is `open -na ghostty --args ...`.
- **Implication:** The CLI is not a viable control plane for the dashboard. AppleScript or D-Bus is the right layer.

### 4. Keybindings cannot launch external scripts

- **Evidence:** [`ghostty.org/docs/config/keybind/reference`](https://ghostty.org/docs/config/keybind/reference), corroborated in shell-integration discussion.
- Keybinds are limited to terminal text/escape sequences and Ghostty's built-in actions. They cannot exec arbitrary commands. The recommended workaround is shell-level keybindings.
- **Implication:** A dashboard cannot register a Ghostty hotkey that, e.g., posts the focused tab to an HTTP endpoint. Bidirectional integration must happen via AppleScript polling or shell-side hooks (e.g., a fish/zsh prompt-hook that POSTs cwd + tab id to the dashboard).

### 5. OSC sequence support is minimal

- **Evidence:** [`ghostty.org/docs/vt/external`](https://ghostty.org/docs/vt/external) — only OSC 8 (hyperlinks) and OSC 21 (Kitty color stack) are listed under "external protocols". Full OSC reference at [`ghostty.org/docs/vt/reference`](https://ghostty.org/docs/vt/reference).
- Ghostty does support standard window/tab title sequences (OSC 0/1/2) inherited from xterm; that's how a shell can rename a tab dynamically and the dashboard can read the title via AppleScript's `tab.name`. But there is no Ghostty-specific OSC for "tag this tab with project ID X" or similar metadata.
- **Implication:** The cleanest correlation between dashboard project state and a specific Ghostty tab is via working directory (already exposed in `Ghostty.sdef`). Tab titles can be a secondary signal if the shell prompt sets them.

### 6. cmux exists and is the closest "Ghostty-native multi-agent shell"

- **Evidence:** [`cmux.com`](https://cmux.com/), [`github.com/manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux) (GPL-3.0).
- cmux is a native macOS Swift/AppKit app that **uses libghostty as a rendering library** (analogous to apps embedding WebKit). It adds: vertical+horizontal tabs with sidebar metadata (git branch, PR status, cwd, listening ports), notification rings when agents need attention, a CLI, scriptable hooks for Claude Code, and a **socket API for automation** including creating workspaces, splitting panes, sending keystrokes.
- Reads existing Ghostty config (themes, fonts, colors).
- Explicitly supports Claude Code's "teammate mode" and Codex sessions.
- **Implication:** This is the most important alternative architecture. If the user is willing to *replace* Ghostty.app with cmux.app (same renderer, different shell), they get a socket API, per-session metadata, and notification rings out of the box. The user said "do NOT replace Ghostty" — but cmux is arguably closer to "extended Ghostty" than to a replacement.

## Verdict on Q1: per-tab focus from an external app

**Feasible on macOS, today, via AppleScript.** Not feasible cross-platform, and not feasible via a Ghostty CLI.

Practical recommendation for the dashboard:

1. **Primary control plane: AppleScript** via `osascript` or NSAppleScript (Swift/Obj-C if native, `subprocess` if Python/Node). The flow is:
   - On dashboard tick: list every Ghostty tab; for each, capture `(window.id, tab.id, tab.index, focused terminal.working directory, tab.name)`.
   - Build a mapping `cwd -> (window, tab)`.
   - When user clicks "jump to project X", look up the tab and call `activate window <id>` then `select tab <id>` (or `focus` on the focused terminal).
2. **Correlation key: working directory** (most reliable; survives tab title rewrites). Tab title is a secondary signal.
3. **Linux fallback (if ever needed):** D-Bus, mirroring `ghostty +new-window`. Not a current priority since the user is on macOS.
4. **AppleScript polling cadence:** AppleScript over `osascript` is slow (~50–200ms per call). Polling every 2–5 seconds is fine; sub-second polling would burn CPU. For low-latency state, get the shell to push (prompt hook posts to dashboard daemon) instead of having the dashboard pull.

### What this does NOT solve

- **No event subscription.** AppleScript is request/response only; the dashboard cannot subscribe to "tab focus changed" or "user typed in this tab." If "current focused tab" matters, the dashboard must poll.
- **No way to inject a non-keystroke control message.** To send the agent a prompt, the dashboard would `input text` (literally types into the terminal). Acceptable but coarse.
- **No reliable identifier across Ghostty restarts.** `window.id` and `tab.id` are session-scoped. Dashboard mapping must be cwd-based, not id-based.
- **No multi-platform out of the box.** macOS-only for v1 is an explicit limitation.

## Validated Assumptions

| Assumption | Status | Evidence |
|---|---|---|
| Ghostty exposes some IPC mechanism a sibling app can use | Partial | macOS AppleScript yes; cross-platform no; Unix socket explicitly deferred |
| There's a `ghostty +focus-tab` CLI | Incorrect | No CLI control surface; #12136 closed not planned |
| External tools can trigger Ghostty keybinds | Incorrect | Keybinds cannot exec external commands |
| AppleScript can per-tab focus, not just per-window | Confirmed | `select tab` + `activate window` exposed in `Ghostty.sdef` |
| Tab can be correlated to a project via working directory | Confirmed | `terminal.working directory` exposed |
| Mitchell wants a broad scripting API | Incorrect (skeptical) | Maintainer explicitly favors scoped per-platform IPC; rejected broad API |

## Risks Identified

### 1. macOS AppleScript permission prompts (Severity: Medium)
First time the dashboard issues a `tell application "Ghostty"`, macOS will prompt for Automation permission. Deny = dashboard is dead. Document this; ship a "Grant access" onboarding screen.

### 2. AppleScript latency budget (Severity: Medium)
Per-call latency 50–200ms means the dashboard's "live state" is at best 1–5Hz. Acceptable for human-in-the-loop UX; not acceptable for "react instantly to focus changes". Push from the shell when low latency matters.

### 3. Ghostty might add a different scripting API later that obsoletes the AppleScript path (Severity: Low)
Maintainer has signaled platform-native is the long-term direction. AppleScript is platform-native on macOS, so this risk is lower than it sounds — but watch [Discussion #2353](https://github.com/ghostty-org/ghostty/discussions/2353) for changes.

### 4. cmux exists (Severity: Medium — strategic, not technical)
If the user prefers cmux over Ghostty.app, much of the dashboard's "watch and focus" job is solved upstream. The dashboard's value prop must justify why Ghostty + custom dashboard beats just adopting cmux. (See `08-revised-viability.md`.)

### 5. Linux users get nothing (Severity: Low for v1)
The user is on macOS. If the project ever needs Linux support, the entire control layer must be reimplemented against D-Bus. Not v1's problem; flag for later.

## Open Questions

- [ ] Does AppleScript expose a way to subscribe to focus changes (Cocoa notifications), or is polling the only option? (Likely polling only; verify in `Ghostty.sdef`.)
- [ ] What happens to AppleScript visibility when Ghostty is in a Mission Control "Spaces" / different desktop? Does `activate window` work cross-Space?
- [ ] Does Ghostty support setting a custom tab title via shell that survives shell prompt redraws? (Standard OSC 2 should; verify with Ghostty.)
- [ ] Can the shell prompt-hook write to a Unix socket that the dashboard daemon owns, eliminating polling for "what's the cwd here"?

## Recommendations

1. **Bet on AppleScript** for the macOS POC. Treat it as a stable, supported integration surface — it's listed in official Ghostty docs and the `.sdef` file is in the main repo.
2. **Push critical state from the shell**, don't pull. Have a shell prompt hook (zsh `precmd`, fish `fish_prompt`) POST `{cwd, tab_title, agent_state_hint}` to the local dashboard daemon. AppleScript is then only used for the focus/activate action.
3. **Keep cmux on the radar.** If cmux develops a stable extension API and matures past 1.0, "build the dashboard as a cmux extension" might dominate "build the dashboard as a Ghostty sibling." Track over the next 3–6 months.
4. **Don't promise cross-platform** in the POC scope. Document macOS-only and move on.

## References

- [Ghostty AppleScript docs](https://ghostty.org/docs/features/applescript)
- [Ghostty.sdef source of truth](https://github.com/ghostty-org/ghostty/blob/main/macos/Ghostty.sdef)
- [Discussion #2353 — Scripting API status](https://github.com/ghostty-org/ghostty/discussions/2353)
- [Discussion #4579 — open new tab in existing instance from CLI](https://github.com/ghostty-org/ghostty/discussions/4579)
- [Discussion #3445 — create new tab/window via CLI](https://github.com/ghostty-org/ghostty/discussions/3445)
- [Issue #12136 — CLI: support opening new tabs in an existing window (closed not planned)](https://github.com/ghostty-org/ghostty/issues/12136)
- [Ghostty External Protocols (OSC)](https://ghostty.org/docs/vt/external)
- [Ghostty Action Reference (keybindings)](https://ghostty.org/docs/config/keybind/reference)
- [cmux.com](https://cmux.com/)
- [github.com/manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)
