# US-005: Multi-tool hook normalization (stretch — the colleague unlock)

**Status:** Draft
**Priority:** Could Have (stretch; enabled by US-003, not required for cutover DoD)
**Persona:** Colleague using a non-Claude agent (Cursor / Codex / Gemini)
**Estimated Complexity:** M
**Last Updated:** 2026-06-26

## User Story

As a **colleague who codes with Cursor (or Codex, or Gemini) instead of Claude Code**,
I want **my agent's hooks to light up the same board signals**,
So that **the mission-control board works for my sessions too, not just Claude's**.

## Description

The observe-only file sink (US-003) makes this nearly free: any agent that can run a hook command
can append a line to the same event file. The work is (a) a per-agent **installer** that writes the
right snippet into that agent's own config (the cmux-reverse-engineered locations), and (b)
extending the Swift normalizer so each agent's event names map into the existing `SignalKind`s.
This is the differentiator the cmux evaluation surfaced — multi-tool support is *config + one event
map*, **not** a terminal fork. ([[cmux-detection-is-hooks-not-terminal-scraping]].)

## Acceptance Criteria

- [ ] **AC1 — Cursor parity:** A Cursor `stop` / `afterAgentResponse` event in the file lights the
  board **identically** to a Claude `Stop`; a `beforeShellExecution` reads as "waiting on you".
- [ ] **AC2 — installer:** A per-agent installer writes the forwarding snippet into the agent's
  config (`~/.cursor/hooks.json` flat; `~/.codex/hooks.json` + `hooks=true` in `config.toml`;
  `~/.gemini/settings.json` nested) — mirroring how `enable-board-hooks.sh` does it for Claude.
- [ ] **AC3 — provider-labeled:** Sessions are tagged with their provider so the board/quota can
  distinguish a Cursor session from a Claude one.

## Edge Cases

1. **Agent config absent** — the agent isn't installed → installer is a no-op with a clear message,
   not a created-empty-config side effect.
2. **Unknown event name** — an agent emits an event not in the map → normalizes to `UNKNOWN`
   (board shows the session but no false "done"/"waiting" claim), same as Claude's fallback.

## Dependencies

- **Requires:** US-003 (the file sink + Swift normalizer it extends).
- **Reference:** the Rosetta-Stone table in `cmux-detection-is-hooks-not-terminal-scraping` memory
  and `CMUXCLI+AgentHookDefinitions.swift` (clean-room the *interface facts*, not the GPL code).

## Related Decisions

- DD-002 (one sink, many writers — multi-tool falls out of the file design for free).

## Notes

**Explicitly a stretch.** Phase 03's cutover DoD does **not** depend on this. It is documented here
because it is the payoff that motivated the whole "do I even need the sidecar" thread — and because
the file sink should be designed (line schema with a `provider` field) so this lands without rework.
