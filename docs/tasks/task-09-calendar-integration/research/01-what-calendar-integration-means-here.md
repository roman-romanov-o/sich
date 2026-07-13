# Research: What "Calendar Integration" means for this product

**Date:** 2026-07-08
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

The repo's own documents already define calendar integration precisely — and narrowly. It is **read-only free/busy ingestion feeding the capacity/attention planner** (task-06's Proactive Mission Control policy, "Phase B: read-only calendar/free-busy adapter"), NOT meeting management, NOT event writing, and — explicitly rejected in task-02 DD-001 — NOT ambient effort capture. Any task-09 scope that writes events, reads titles/attendees by default, or infers effort from calendar blocks contradicts accepted decisions.

**The calendar drives two planning axes, not one.** It is not merely "when is the human free to rest." Free/busy is a constraint on **both** dimensions this product allocates: (a) **workflow** — which task to run next and how much focus time fits before the next hard boundary; and (b) **token/quota usage** — pacing agent work against the interactive-pool quota window so token-heavy runs land inside available human-attended time and clear before a meeting or a quota reset. The calendar and the quota gauge are the two capacity inputs the planner fuses; calendar answers "how much wall-clock attention is left," quota answers "how much token budget is left," and the plan must respect whichever runs out first.

## Research Questions

1. Does the product vision mention calendar at all, and in what role?
2. Which interpretation does prior planning (task-02, task-06) support or forbid?
3. Is there any code today that consumes calendar data?

## Key Findings

### 1. The vision seed is a one-liner about scheduling optimization, not meetings

**Evidence:** `docs/further-ideas.md:3-4`

```
- Sync with calendars, so we can make optimizations, on which task we should work next
- Emphasize, that human is single-threaded, and optimization for that puprose, planning of rest based on calendar
```

**Implication:** The founding idea is *task-selection and rest-planning around calendar constraints* — the human is the single-threaded resource, the calendar tells us when that resource is unavailable. It is capacity planning, not a calendar client. Concretely, the two named optimizations map to the two planning axes above: "which task we should work next" is **workflow** planning, and pairing that with the quota gauge (the interactive pool's token window) is **token-usage** planning — schedule the token-heavy run for the window where the human is actually present to attend it and it can finish before the next busy block or reset.

---

### 2. Task-06 has already specified the calendar contract in detail — task-09 should implement, not re-invent it

**Evidence:** `docs/tasks/task-06-proactive-mission-control/task-description.md` §6.2 (Calendar inputs), §13 (fallbacks), §17 (rollout)

The spec (Status: Review, description Done) requires:
- **Free/busy intervals only** over a lookahead horizon; "Titles, attendees, and descriptions are not part of the default contract" (line ~135).
- UTC instants carrying source IANA zone, half-open `[start, end)` windows, all-day = busy, overlapping calendars unioned (lines ~138-145).
- Calendar freshness and permission state as first-class inputs (line ~133).
- "Calendar is a hard boundary. Focus work must fit before the next busy [block]" (line ~73).
- Degradation ladder: "Calendar unavailable/stale → Avoid 'meeting-free' claims… or ask for a free-until time" (line ~988); "no calendar/operator availability → manual free-until actions only" (line ~1178).
- **Rollout order:** Phase A ships with *manual `available until` / absence input; no inferred calendar-free claim* (line ~1113). Phase B enables the "read-only calendar/free-busy" adapter *only after its individual tests pass* (line ~1166).

**Implication:** "Calendar integration" = **task-06's Phase B calendar adapter** (plus, arguably, the Phase A manual free-until input that must precede it — neither exists in code). The contract is already frozen at the policy level: free/busy only, read-only, freshness-labeled, with an explicit no-calendar degraded mode.

---

### 3. Calendar-as-effort-source was considered and REJECTED

**Evidence:** `docs/tasks/task-02-estimation/design-decisions/DD-001-effort-attribution-pomodoro-self-report.md` (Option 2, "Ambient OS / active-window + calendar capture")

Option 2 (passively read calendar-busy blocks and attribute them to cards) was rejected as "Surveillance… fights the calm-cockpit identity and the watcher discipline" with "heuristic (wrong) attribution". The accepted mechanism for invisible-work awareness is the Pomodoro self-report (DD-001) fed via a loose-coupled effort log from the sibling `macos-flow` app (DD-002).

**Implication:** Task-09 must NOT frame calendar as "where did the human's time go". Calendar answers **"when is the human unavailable next"** (forward-looking availability), Pomodoro answers **"what was worked on"** (backward-looking effort). These are different accepted decisions; conflating them re-opens a settled surveillance argument.

---

### 4. Zero calendar-integration code exists today

**Evidence:** repo-wide grep for `calendar|EventKit|freeBusy|ManualAssertion|availableUntil` over `app/Sources` and `app/Tests` matches only `app/Sources/GhostlingCore/ClaudeUsagePanel.swift:36-115`, which uses Foundation's `Calendar` type for date arithmetic when parsing `/usage` reset strings — unrelated to calendar integration.

**Implication:** This is a green-field feature. Even task-06's Phase A prerequisite (manual free-until assertion) is unimplemented.

## Validated Assumptions

| Assumption | Status | Evidence |
|------------|--------|----------|
| "Calendar integration" is a documented product direction | Confirmed | `docs/further-ideas.md:3-4`; task-06 §6.2 |
| It means meeting/event management or 2-way sync | Incorrect | task-06 explicitly limits to read-only free/busy; DD-001 rejects content capture |
| Some calendar plumbing already exists to extend | Incorrect | Only Foundation `Calendar` date math (`ClaudeUsagePanel.swift:36`) |
| task-06 policy is approved and ready to consume calendar data | Partial | task-06 Status: **Review** — description done, user stories/DDs/plan pending; the consumer is specified but not built |

## Risks Identified

### 1. Building the adapter before its consumer exists (Severity: Medium)

**Description:** task-06's advisor — the thing that *uses* free/busy — has no user stories, no code. A calendar adapter with no consumer risks shipping green-but-unreachable (the exact failure of task-08's Planning Mode, per project memory: "bound to a green test ≠ reachable by a user").

**Mitigation:** Give task-09 its own minimal, directly-visible consumer: render the next hard boundary ("free until 14:00 · standup") in the existing capacity panel next to the quota reset lines, and feed the existing `QuotaAdvisor` headline. Do not wait for the full task-06 advisor.

### 2. Scope creep toward task-06 (Severity: High)

**Description:** task-06's description is ~1200 lines of policy. If task-09 tries to implement "calendar-aware recommendations" wholesale, it swallows task-06.

**Mitigation:** Hard boundary: task-09 = data in (free/busy provider + manual free-until) + one visible surface. Policy/optimizer stays in task-06.

## Open Questions

- [ ] Should task-09 also deliver task-06's Phase A manual free-until input (it is the specified fallback and simpler than any API)? Recommended: yes — it is the degraded mode the adapter must fall back to anyway.
- [ ] Does the operator's real calendar live in macOS Calendar.app (which would make EventKit sufficient, including for Google accounts added there)? Needs a one-question user confirmation.

## Recommendations

Scope task-09 as: **read-only free/busy provider (+ manual free-until fallback) surfaced as a "next hard boundary" signal in the capacity panel**, sitting alongside the quota gauge so the two feed one plan — calendar bounds available *attention time*, quota bounds available *token budget*, and both gate when the next token-heavy run should start. Explicitly implement task-06 §6.2's input contract, deferring all policy to task-06. Forbid: event writing, title/attendee reading by default, calendar-derived effort attribution.

## References

- `docs/further-ideas.md`
- `docs/tasks/task-06-proactive-mission-control/task-description.md` §6.2, §13, §17
- `docs/tasks/task-02-estimation/design-decisions/DD-001-effort-attribution-pomodoro-self-report.md`, `DD-002-pomodoro-integration-coupling.md`
