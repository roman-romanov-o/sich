# Research: The `claude -p` / Agent SDK Quota Split (June 2026) and Why It Forces a Watcher Architecture

**Date:** 2026-06-15
**Status:** Complete
**Researcher:** Claude (verified via claude-code-guide against official docs)
**Affects:** `07-orchestrator-landscape.md`, `08-revised-viability.md`, `task-description.md` constraints.

## Summary

As of **2026-06-15**, non-interactive Claude Code usage — `claude -p` / `--print` (headless mode) and anything built on the Claude Agent SDK — **no longer counts against the interactive subscription limits**. It draws instead from a **separate monthly Agent SDK credit pool**, and when that pool is exhausted, non-interactive requests **stop entirely** (no fallback to interactive limits) unless overflow billing is manually enabled. The credit does not roll over.

For this project, that is not a minor pricing footnote — it **removes the spawner architecture from contention on economic grounds**, for the exact audience the product targets (subscription users running parallel agents). It simultaneously **strengthens** every prior recommendation: build a *watcher* of native interactive sessions, never a *spawner* of headless ones. It also adds a second Anthropic quota pool the dashboard must track.

## What changed (confirmed)

| Fact | Detail |
|---|---|
| Effective date | **2026-06-15** |
| What's affected | `claude -p` / `--print`, Claude Agent SDK (Python/TS), and third-party apps built on the Agent SDK |
| What's NOT affected | Interactive `claude` sessions, Claude.ai web chat, Claude Cowork — these keep using subscription limits unchanged |
| New pool sizes | Pro **$20/mo**, Max 5x **$100/mo**, Max 20x **$200/mo**, Team/Enterprise varies by seat |
| Exhaustion behavior | Non-interactive requests **stop**; no automatic fallback to interactive limits; manual overflow billing only |
| Rollover | None — monthly credit does not carry over |
| Pay-as-you-go API keys | Unaffected; standard per-use billing, no credit granted |

### Interactive limits (for contrast, the pool we actually want to track)

- **5-hour rolling window** (shared across Claude Code, Claude.ai chat, Cowork) — doubled for Pro/Max/Team/Enterprise as of 2026-05-06; peak-hours reduction removed for Pro/Max.
- **Weekly cap** on active compute hours per plan (exact per-plan numbers not published; check the Console billing dashboard).

**Sources** (verified 2026-06-15):
- [Use the Claude Agent SDK with your Claude plan](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
- [Run Claude Code programmatically (headless)](https://code.claude.com/docs/en/headless.md)
- [Manage costs effectively](https://code.claude.com/docs/en/costs.md)
- [Anthropic Ends Subscription Subsidy for Agents June 15](https://www.techtimes.com/articles/317625/20260602/anthropic-ends-subscription-subsidy-agents-june-15-credit-pool-replaces-flat-rate-access.htm)

*Not verified:* exact per-plan weekly hour caps; whether other providers (Codex, Gemini CLI) will follow with a similar headless/interactive split (worth monitoring).

## Why this forces a watcher, not a spawner

The viability doc (`08`) already preferred a watcher for a *workflow* reason: the user's vision is "watch my existing Ghostty sessions," not "let a tool own the workspace." The June-15 change adds a harder, *economic* reason:

1. **A spawner that runs `claude -p` burns the wrong pool.** It consumes the small, capped Agent SDK credit ($20 on Pro) — not the subscription limits the user lives in and wants to conserve. For a tool whose entire value prop is *quota awareness*, spending an invisible second pool to do its work is self-defeating.
2. **The pool hard-stops with no fallback.** A spawner-based "mission control" would silently die mid-cycle when the $20 credit runs out, while the user's interactive quota sits untouched. That's a worse failure mode than the problem the tool set out to solve.
3. **It makes the quota model incoherent.** If the tool itself generates headless load, "remaining quota" becomes a function of the tool's own activity rather than the user's real work. A pure observer of interactive sessions keeps the measurement clean.

**Conclusion:** the product must drive/observe the **native interactive `claude` running in a real Ghostty PTY**, and derive all state from **observation signals only** (hooks, JSONL transcript tail, statusline JSON, OTEL). It must never invoke `claude -p` as part of its own operation.

### Corollary design constraints

- **No LLM calls in the daemon's hot path via `claude -p`.** If a feature wants natural-language summarization of a session ("what is this agent doing?"), do it deterministically from the transcript/hook payloads, or make it an explicit opt-in that the user understands spends the Agent SDK credit. Default: zero headless spend.
- **The MCP-server façade (deferred to v2) stays observe-only.** Exposing "what's my remaining quota / which sessions are blocked" as MCP tools is fine — that's read-only. It must not turn into "dispatch a `claude -p` task," which would reintroduce the spawner problem.
- **Quota pillar now tracks two Anthropic pools.** (a) interactive 5h-window + weekly cap, and (b) the separate Agent SDK credit. Show both; label which is which. A user who *does* run headless automation elsewhere will want to see that second pool drain.

## Impact on the competitive landscape

This re-scores the spawner-shaped tools for a subscription user specifically:

- **Vibe Kanban** — spawner. Post-June-15, running its agents on a subscription burns the Agent SDK credit, not interactive quota. Previously dinged only for *sunsetting + model mismatch*; the **economic disqualifier is now the headline** for this user. "Vibe Kanban doesn't solve this" is correct and now first-class.
- **Conductor, Crystal, Claude Squad, container-use, sketch.dev** — all spawners; same economic caveat applies the moment they drive Claude headlessly on a subscription.
- **cmux** — the closest existing tool, and notably *not* purely a spawner: it attaches to / controls sessions via libghostty + socket API and integrates Claude Code as a teammate. It remains the strongest "buy not build" candidate for the session-view half. The June-15 change doesn't hurt cmux's standing; if anything it widens the gap to the pure spawners. (Still gated on the "is libghostty.app close enough to Ghostty.app" question from `08`.)

The takeaway is not "build something new because of this change" — the watcher recommendation already stood. It's that the change **removes ambiguity**: the spawner alternatives are now economically wrong for the target user, so the watcher niche the product occupies is cleaner and better-defended than `08` assumed.

## Validated assumptions

| Assumption | Status | Evidence |
|---|---|---|
| `claude -p` now uses a separate quota from interactive | **Confirmed** | Support article + headless docs, effective 2026-06-15 |
| Separate pool hard-stops with no interactive fallback | **Confirmed** | Support article (overflow billing is manual opt-in) |
| Interactive sessions still use subscription limits unchanged | **Confirmed** | Same sources; only Agent SDK / headless moved |
| Observation signals (hooks/JSONL/statusline/OTEL) cover the watcher's needs without any headless spend | **Confirmed** | `06-agent-state-detection.md` + official hooks/sessions/observability docs |
| Codex / Gemini will introduce a similar split | **Unverified** | No evidence yet; monitor |

## Risks

1. **Pool sizes / mechanics may change again (Severity: Medium).** Anthropic shifted this once; treat the two-pool model as a moving target. Localize quota parsing behind an adapter so a future change is a small edit.
2. **Users may not realize their existing spawner tools now drain the new pool (Severity: Low, but a real value-add).** The dashboard surfacing "your Agent SDK credit is 80% gone — that's Vibe Kanban, not your interactive work" is genuinely useful and uniquely possible because the tool tracks both pools.
3. **Tempting feature creep toward dispatch (Severity: Medium).** "Spare capacity → start project X" is in the original vision. Implement *suggestion*, not *auto-dispatch via `claude -p`*. Auto-dispatch reintroduces the spawner problem and the wrong-pool spend. Keep the human in the loop launching the interactive session.

## Recommendations

1. **Codify "watcher, never spawner; never `claude -p`" as a hard product constraint**, not a preference. (Added to `task-description.md` constraints.)
2. **Quota pillar v1 tracks both Anthropic pools** (interactive + Agent SDK credit), clearly labeled. Update the v1 acceptance criteria in `08` accordingly.
3. **The backlog→capacity feature suggests, it does not dispatch.** Human launches the interactive session in Ghostty; the tool only recommends.
4. **Add "providers introduce headless/interactive quota splits" to the watch list** — if Codex/Gemini follow, the two-pool tracking generalizes and the tool's cross-provider quota view becomes more valuable, not less.

## References

- `06-agent-state-detection.md` — confirms all needed state comes from observation signals (no headless spend required).
- `07-orchestrator-landscape.md` — spawner vs. watcher taxonomy this note re-scores.
- `08-revised-viability.md` — the build/watcher recommendation this note hardens.
- `02-provider-data-availability.md` — quota data sources (now two Anthropic pools).
