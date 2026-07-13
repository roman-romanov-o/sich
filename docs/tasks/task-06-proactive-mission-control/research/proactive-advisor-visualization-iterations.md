# Proactive Advisor Visualization: Review Iterations

**Status:** Complete
**Date:** 2026-07-05
**Canonical artifact:** [proactive-advisor-visualization.md](proactive-advisor-visualization.md)

This file records five adversarial reviews of the schematic concept. Each
iteration changes the canonical research before the next review.

## Iteration 1 — Now + Runway + Fleet

### Proposal

Make the bounded recommendation the primary object, align human and agent
activity on a shared runway, and simplify the everyday board into Needs You,
Working, Review, and Prepared zones. Treat interactive Claude turns as
alternating attention ownership rather than continuously occupied human time.

### Reviewer critique

- “Attention free” confused agent turn ownership with a policy-safe opportunity
  for another human task.
- Conditional overnight work looked scheduled and automatic.
- Fleet zones did not follow required human-action precedence, and sample timing
  was internally inconsistent.
- A full multi-lane runway would collapse under the expected 6–8 sessions.
- “Start” controls could imply timer/agent execution authority.
- The handoff lacked a state/transition contract for difficult fixtures.

### Resolution

- Split `TURN OWNER` from `OPERATOR OPPORTUNITY` and show an admitted safe-slice
  duration rather than “free.”
- Added distinct grammar for firm, observed, tentative, and conditional states;
  unlaunched work is explicitly manual and not scheduled.
- Replaced Fleet zones with Act Now, Agent Owns Turn, Completion Queue, and
  Ready Next using deterministic precedence.
- Collapsed the home runway to one selected lane plus aggregates and added
  eight-session overflow fixtures.
- Renamed controls to acknowledgements and persistent advisory-only copy.
- Added a component/state matrix with source, presentation, placement, controls,
  transitions, and edge fixtures.

## Iteration 2 — Truthful attention and conditional state

### Proposal

The revised concept distinguishes turn ownership from reusable attention,
visually separates options from observed execution, scales the runway through
selection/aggregation, and gives the designer a deterministic component-state
contract.

### Reviewer critique

- `ACT NOW` contradicted a protected focus recommendation when the contained
  request was actually queued.
- `Safe slice 0m` contradicted an 18-minute continuation because it did not
  distinguish new-task switching from continuing current context.
- Proposed human slices looked like firm calendar commitments before
  acknowledgement.
- The overnight option omitted integration and post-integration verification
  obligations and invalidation.
- Simultaneous requests, review-cap overload, and accepted conflicts lacked
  visible ordering and resolution.
- `READY NEXT` incorrectly admitted raw backlog beside verified work.

### Resolution

- Split attention into `INTERRUPTS NOW` and `QUEUED FOR BOUNDARY`; only the
  former replaces the Now recommendation.
- Renamed the lane metric `NEW-TASK GAP` and added a separate global protected
  operator line.
- Added proposed, acknowledged, and observed human-slice grammar/transitions.
- Expanded the conditional tail through review, integration, final verification,
  and release-on-invalidation.
- Added deterministic ordering, overflow summaries, conflict/debt fixtures, and
  explicit user resolutions.
- Restricted Ready Next to admitted actions; raw backlog is a non-admitted
  candidate with its first missing gate.

## Iteration 3 — Delivery hierarchy and complete commitments

### Proposal

The home screen now has one unambiguous action: interrupting requests become
Now, while other responses name their queue boundary. Human timeline blocks
express proposal state, and autonomous options show their complete conditional
obligations.

### Reviewer critique

- Interrupt eligibility ignored passive mode, quiet hours, mute, snooze, and
  notification caps.
- Decisive stale evidence was treated like harmless low-priority card metadata.
- Controls and the Space shortcut had undefined or inconsistent mutations.
- Runway strokes were ambiguous and future review lacked a textual commitment
  state.
- Concurrent returns lacked bundling, invalidation, ordering, and escalation.
- Confidence and desktop/accessibility contracts were incomplete.

### Resolution

- Split interrupt eligibility from delivery; only delivered interrupts replace
  Now.
- Split entity staleness from decisive-source expiry, which withdraws/recomputes
  the recommendation.
- Added a control-effect matrix and limited Space to proposed human slices.
- Added persistent text tokens, time scale/ticks, scroll behavior, and
  observed-before-now versus proposed-after-now segmentation.
- Added a current-set boundary bundle for concurrent returns, resolution,
  escalation, mute, quiet hours, and caps.
- Added human-readable confidence summaries, full Why dimensions, viewport,
  sticky/scroll/overlay, focus, truncation, and non-color accessibility rules.

## Iteration 4 — Delivery authority and uniquely decodable time

### Proposal

The concept now distinguishes policy severity from user-authorized delivery,
withdraws advice when decisive evidence expires, gives every control an exact
effect, labels every runway segment in text, and specifies concurrent-return
bundling plus desktop/accessibility behavior.

### Reviewer critique

- Legacy Needs You/Act Now vocabulary and replacement behavior still
  contradicted the canonical attention strip and delivery authorization.
- Accepted schedule conflict and a delivered SLA request could both claim Now.
- Advisory-only effects were described but not located in the schematics.
- Empty/current, loading, unavailable, denied, and uncertain-session states
  were conflated.
- Collapsed confidence exposed Phase/search jargon rather than user
  consequences.
- The loose screen list omitted many states required by the component contract.

### Resolution

- Added one canonical terminology/behavior box and removed legacy references.
- Added one primary-action arbitration rule; delivery triggers recomputation
  rather than automatically winning.
- Put a context-specific `Effect:` line under primary controls and defined its
  post-action state token.
- Added distinct source-health fixtures and removed unknown sessions from live
  counts and return estimates.
- Replaced collapsed internal jargon with fit/uncertainty/override consequences;
  technical metadata is tertiary.
- Replaced the screen list with a required surface × fixture × transition ×
  clickable deliverable matrix using canonical timeline tokens.

## Iteration 5 — Canonical handoff contract

### Proposal

The concept now has one vocabulary, one Now arbitration rule, explicit
side-effect copy, distinct source-health states, consequence-based confidence,
and a complete required deliverable matrix.

### Reviewer critique

- One stale rule still let `ELIGIBLE` attention replace Now, and the boundary
  bundle showed a competing second recommendation.
- Normal and eight-session fixtures had inconsistent live/unknown counts.
- Meeting and overnight segments omitted exact canonical timeline tokens.
- Failed-result delivery was missing, and source recovery was marked
  non-interactive despite required transitions.
- Non-Space single-key shortcuts could hijack terminal/editor input.

### Resolution

- Restricted Now replacement to a delivered request that wins recomputation and
  changed the boundary bundle to one explicit Now update.
- Reconciled all normal/stress counts and moved the unknown session to Source
  Status outside working/ETA totals.
- Labeled meeting, review, integration, and verification segments with
  `FIRM CALENDAR` or `TENTATIVE`.
- Added a clickable failed-result flow and interactive/paired source recovery
  deliverables.
- Disabled every single-key shortcut inside text inputs, editors, and terminals.

### Final verification

The reviewer confirmed:

- eligible/delivered/queued vocabulary and single-Now behavior are consistent;
- normal and eight-session counts exclude uncertain sessions correctly;
- every time segment uses canonical state tokens;
- failed-result and source-recovery deliverables are present;
- all shortcuts are disabled in inputs, editors, and terminals;
- control-effect copy is located in each corrected schematic.

**Reviewer verdict:** Approved for designer handoff.
