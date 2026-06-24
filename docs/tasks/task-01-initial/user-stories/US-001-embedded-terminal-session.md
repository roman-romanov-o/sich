# US-001: Launch/attach a session in the app's embedded terminal

**Priority:** Must Have
**Status:** Draft
**Persona:** Operator
**Estimated Complexity:** XL

## User Story

As an **Operator**,
I want to **launch or attach an interactive `claude` session inside the app's own embedded (libghostty) terminal**,
So that **the board and the live terminal live in one window, and the app can read the session's PTY directly instead of screen-scraping**.

## Acceptance Criteria

1. **Given** the app is running on macOS,
   **When** I open the embedded terminal for a new session,
   **Then** a real interactive shell renders inside the app (libghostty), and I can run `claude` in it exactly as in Ghostty.app (config/keybindings honored).

2. **Given** a session is running in the embedded terminal,
   **When** the agent produces output,
   **Then** the app has direct read access to the PTY contents (no AppleScript, no screen-scrape).

3. **Given** I launch an agent session through the app,
   **When** the launch occurs,
   **Then** it runs **native interactive `claude`** (interactive pool) and the app performs **zero** `claude -p` / Agent SDK calls on my behalf (pool firewall — DD-001 / watcher constraint).

## Edge Cases

1. **libghostty embedding API unstable / breaks on upgrade**
   - Trigger: a pinned libghostty revision changes signatures or fails to render.
   - Expected behavior: the Phase-0 embedding smoke test (see Technical Notes) fails loudly in CI; the app does not ship a broken terminal. Fallback path is DD-001's Option 3 (ride cmux), recorded as a superseding decision if triggered.

2. **A managed session exits / crashes**
   - Trigger: the shell or `claude` process terminates unexpectedly.
   - Expected behavior: the terminal surface shows the exit cleanly; the corresponding board card moves to a terminal/`done`-or-`blocked` state rather than going stale.

## Technical Notes

- Implements **DD-001** (embed libghostty, become the terminal — cmux model, Swift/AppKit + libghostty C API, macOS-first). Study `ghostty-org/ghostling` first.
- **Phase-0 gate:** a throwaway embedding spike must prove the rendering/input layer is stable enough *before* app architecture is built on it. This is the highest-risk story.
- The **pool firewall** (no auto `claude -p`) must be enforced in code, not just by convention — owning a read/write PTY makes dispatch-creep easy.

## Dependencies

- **Requires:** none (foundational).
- **Enables:** US-002 (drill into terminal), US-003/US-004 (board + state read from PTY/hooks).

## Questions

- [ ] Does the app spawn the shell, or attach to a shell the user starts? (Spawning a *shell* is fine; spawning `claude -p` is forbidden — clarify the boundary in DD-002.)

## Related

- Task: [`../task-description.md`](../task-description.md) (Desired Solution A)
- Research: `../research/13-board-view-and-feature-parity.md`, `../research/14-ui-mockup-critique.md`
- Design Decision: **DD-001** (terminal substrate — embed libghostty)
