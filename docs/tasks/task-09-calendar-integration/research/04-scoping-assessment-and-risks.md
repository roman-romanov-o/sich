# Research: Is task-09 well-founded? Scoping assessment and risks

**Date:** 2026-07-08
**Status:** Complete
**Researcher:** Sahaidachny Research Agent

## Summary

The task is well-founded but only under a narrow reading: it is the *availability-ingestion slice* of the already-specified task-06 policy, plus one directly visible surface. The name "Calendar Integration" invites three wrong products (a meeting UI, a 2-way sync, an effort tracker) that prior decisions forbid. Recommend proceeding with a tightly-scoped description; recommend renaming the intent inside the description to "human availability signal (calendar-fed)".

## Research Questions

1. Is there a real user problem, or is this feature-creep from a one-line idea?
2. What is the minimal scope that is user-reachable (not green-but-unreachable)?
3. What must be explicitly out of scope?

## Key Findings

### 1. The user problem is real and matches the product's core thesis

**Evidence:** task-02 research thesis ("treat human review-attention … as the binding capacity constraint", `docs/tasks/task-02-estimation/README.md`); `docs/further-ideas.md:4` ("human is single-threaded"); task-06 §1 goals ("Protect focused work from low-value interruptions and short calendar gaps").

**Implication:** Today the capacity panel answers "can the *pools* take another launch?" (`QuotaAdvisor`) but not "can the *human*?". A recommendation to `launchInteractive` five minutes before a meeting is wrong in exactly the way the product exists to prevent. Calendar free/busy is the cheapest honest input for that.

### 2. Minimal reachable scope (proposed)

Grounded in what exists (`QuotaPanel` rows, `QuotaAdvisor` seam, `NativeQuotaPoller` pattern — see report 02):

1. **Core availability model** (`GhostlingCore`, pure, no EventKit): busy-interval union, half-open windows, "free until / next boundary" derivation, freshness + source-confidence labels per task-06 §6.2. Unit-testable with injected clock.
2. **Manual free-until input** (task-06 Phase A): a small control in the capacity panel; a `ManualAssertion`-shaped value with `expires_at`. Ships value with zero permissions.
3. **EventKit provider** (`GhostlingApp`, behind the spike from report 03): read-only, strips to intervals at the boundary, per-calendar toggles, explicit `unknown` state on denial/staleness.
4. **Two visible consumers**: (a) an availability row in the capacity panel next to the quota reset lines; (b) `QuotaAdvisor.recommend` gains the boundary as an input — e.g. `hold` with "busy in 12m — shorter than a safe launch" detail. Interaction ACs must dispatch real events per the interaction-AC binding rule (project memory).

Everything else — recommendation policy, focus/recovery, defer-until, batch planning — stays in task-06.

### 3. Explicit non-goals the description must state

**Evidence:** prior decisions cited in reports 01/03.

- No event creation/edits/2-way sync (watcher-not-spawner spirit; task-06: "Zero … calendar writes").
- No title/attendee/description ingestion by default (task-06 §6.2).
- No calendar-derived effort attribution (task-02 DD-001 rejected Option 2).
- No Google Calendar API client, no OAuth, no webview (DD-001 native stance).
- No netting human availability into the two Anthropic pool gauges (never-single-pool invariant).
- Never claim "meeting-free" from stale/absent data — render `unknown` (task-06 §13; quota stack's no-silent-zeros discipline).

## Validated Assumptions

| Assumption | Status | Evidence |
|------------|--------|----------|
| Task-09 is a natural next step | Partial | The *input slice* is; the full calendar-aware advisor belongs to task-06, which is still in Review |
| It can be built without new processes/permissions | Partial | Manual path yes; EventKit path needs a TCC/packaging spike (report 03, Risk 1) |
| The board/panel has a place to surface it | Confirmed | `QuotaPanel`/`QuotaGaugeRow` reset lines; `QuotaAdvisor` headline seam |

## Risks Identified

### 1. Task ordering inversion with task-06 (Severity: Medium)

**Description:** task-06 (the consumer policy) is unapproved (Status: Review). If its §6.2 contract changes during approval, task-09's adapter contract shifts.

**Mitigation:** §6.2's *input* shape (free/busy intervals, freshness, manual assertion) is the most stable part of that spec and is independently useful. Pin task-09 to that subset; note the dependency in the task description so a task-06 revision triggers a review here.

### 2. Green-but-unreachable / visual-AC false passes (Severity: Medium)

**Description:** Project memory documents repeated failures shipping "green" UI that users can't reach or see (task-08 planning entry point; the invisible back-pill).

**Mitigation:** Stories must include a reachable interaction path (panel row visible by default when data exists) and route visual ACs to human sign-off with screenshots, per the established DoD-native flow.

### 3. Timezone/DST correctness (Severity: Low-Medium)

**Description:** task-06 mandates UTC instants + source IANA zones, half-open windows, DST-ambiguity handling for manual local times.

**Mitigation:** Keep all interval math in pure `GhostlingCore` functions with injected `Calendar`/`TimeZone` (existing pattern: `ClaudeUsagePanel.parseReset`, `app/Sources/GhostlingCore/ClaudeUsagePanel.swift:89`); parametrized tests across DST transitions.

## Open Questions

- [ ] User confirmation: which calendar(s) matter, and are they visible in macOS Calendar.app?
- [ ] Should the availability row live in the quota panel or nearer the board's attention indicator (`AttentionIndicator.swift`)? Designer-agent question once stories exist.
- [ ] Does task-09 include the `.app` bundling step if the spike demands it, or is that split into its own task?

## Recommendations

### Proceed With

Write the task description as **"Human availability signal (calendar integration)"**: core interval model + manual free-until + EventKit free/busy provider + availability row + advisor awareness. Order phases so the manual path ships before (and independently of) the EventKit spike.

### Avoid

Any scope from the forbidden list in Finding 3; implementing task-06 policy logic here.

### Consider

Splitting a "Phase 0: EventKit TCC spike" exactly like the libghostty Phase 00 spike (GO/NO-GO artifact), so planning can proceed while packaging reality is established.

## References

- `docs/tasks/task-09-calendar-integration/research/01-what-calendar-integration-means-here.md`
- `docs/tasks/task-09-calendar-integration/research/02-existing-time-and-capacity-surfaces.md`
- `docs/tasks/task-09-calendar-integration/research/03-calendar-source-options-and-packaging.md`
