# US-004: Semantic shell signal (Ghostty shell-integration)

**Priority:** Could Have
**Status:** Ready
**Persona:** Operator
**Estimated Complexity:** M

## User Story

As an **operator**,
I want **the terminal to report cwd and command boundaries semantically**,
So that **the board's directory/command detection is accurate and the render is richer**.

## Acceptance Criteria

1. **Given** shell-integration is installed
   **When** a command runs in a session
   **Then** the current working directory is **reported** to the app (not inferred from process scanning).

2. **Given** the app launches (like the hook installer does)
   **When** installation runs
   **Then** the integration files (`ghostty-integration.zsh`, `xterm-ghostty` terminfo) are installed **idempotently**, preserving the user's existing shell rc.

## Edge Cases

1. **Non-zsh shell**
   - Trigger: operator uses bash/fish.
   - Expected: degrade gracefully (skip or install the matching integration), never break the shell.

2. **Already installed**
   - Trigger: second launch.
   - Expected: no-op; no duplicate rc lines.

## Technical Notes

Mirror `enable-board-hooks.sh` + `HookInstaller.swift` for install; bundle terminfo. This is an **enabler** for US-002's dir-join accuracy; US-002 can also rely on `ppid` alone, so this is Could-Have.

## Dependencies

- **Requires:** none.
- **Enables:** sharper US-002 cwd binding; better terminal render.

## Related

- Task: `../task-description.md` (Scope item 4)
