# Proactive Mission-Control Algorithm: Iteration Record

**Status:** Complete
**Date:** 2026-07-04
**Review method:** Each iteration is critiqued by a separate subagent acting as
an adversarial product/algorithm reviewer. The main agent records the critique,
changes the canonical policy, and asks the reviewer to attack the next version.

The canonical result is
[task-description.md](../task-description.md). This file preserves the reasoning
trail; it is not a second source of truth.

## Iteration 1 — Initial policy

### Proposal

Use a deterministic, receding-horizon advisor with:

- lexicographic human-safety, attention, focus, completion, then quota goals;
- hard gates for calendar fit, recovery, Saha readiness, independent quota
  pools, autonomous concurrency, and review debt;
- explicit candidates for rest, continuing, responding, reviewing, Saha
  planning, launch suggestions, interactive work, and small admin;
- a 24-hour lookahead that back-schedules planning for unattended agent windows;
- confidence-aware p50/p80 duration and quota estimates;
- stable, suggest-only recommendation cards with a now/why/until/then contract.

### Reviewer critique

- Unattended launches were scheduled after the operator had left; suggest-only
  execution requires launch to be back-scheduled and confirmed.
- Scalar quota math could not represent simultaneous rolling and weekly
  constraints or incompatible units.
- An unconditional `CONTINUE` gate contradicted the lexicographic objective and
  could starve deadline-bound review.
- The accepted Pomodoro log has work completions, not the live/break state
  needed to prove recovery is due.
- Calendar fit needed checkpointable attention slices, not whole-task fit.
- Saha verification needed to bind to an immutable readiness revision.

### Resolution

- Added operator availability, manual-launch deadlines, live confirmation, and
  expiry for unattended plans.
- Replaced scalar pool checks with per-unit, time-projected quota constraints.
- Split hard eligibility from a true lexicographic candidate order; continuity
  is now bounded hysteresis.
- Added three-state recovery evidence and a future read-only timer contract.
- Added slice/preemption/checkpoint semantics to human and machine work.
- Bound Saha readiness to hashed/versioned inputs and invalidated it on change.

## Iteration 2 — Feasibility repair

### Proposal

The revised policy now schedules all manual actions while the operator is
available, evaluates every provider constraint in comparable units over time,
uses checkpointable slices for calendar fit, and orders candidates by the
stated objective instead of an unconditional continuation ladder.

### Reviewer critique

- One calendar incorrectly intersected human availability with machine runtime,
  deleting the very unattended intervals the policy intended to use.
- Future quota and review reservations had no stable identity or lifecycle
  across replanning.
- The priority tuple lacked computable classes and deterministic final ties.
- Time-projected quota needed capacity functions and cumulative cost envelopes,
  not scalar totals.
- Parallel tasks could conflict through repositories, branches, services, and
  integration work even when provider capacity was available.
- A live process was too weak to prove an unattended run was ready.

### Resolution

- Split human and machine timelines and connected them with launch prerequisite
  edges.
- Added a persisted plan DAG, node/reservation states, atomic supersession, and
  earliest-deadline-first human allocation.
- Defined ordinal risk classes, slack math, a bounded continuity lease,
  fixed-point ties, and stable IDs as the final order.
- Defined `available_capacity(t)`, `cost_p80(elapsed)`, breakpoints, and a
  conservative concurrent-reservation rule.
- Added isolated workspace/resource claims plus integration review load.
- Added preflight, stabilization, heartbeat, and `unattended_ready`.

## Iteration 3 — Dual timelines and persistent planning

### Proposal

The policy now treats human focus and agent runtime as separate resources,
persists a versioned plan with real reservations, schedules deterministically,
and requires isolated, stable unattended runs rather than merely live
processes.

### Reviewer critique

- Immutable snapshot assembly still allowed a time-of-check/time-of-use race
  against changing calendar, quota, and ledger evidence.
- Firm nodes lacked invalidation/rescheduling semantics, and window time was
  incorrectly part of logical identity.
- Ordinary overdue tasks could dominate critical attention because deadline
  risk preceded attention risk.
- Recovery uncertainty had no typed, escalating action, leaving balance mostly
  non-functional with the current work-only Pomodoro feed.
- Earliest-deadline-first placed nodes but did not define overload admission.
- Generic completion states had no action-specific authoritative evidence.

### Resolution

- Added versioned snapshot envelopes, decisive-source TTLs, compare-and-swap
  installation, and revalidation before user actions.
- Split logical node, attempt, and reservation identity; added blocked,
  invalidated, and failed states with atomic reservation migration.
- Separated hard commitments from soft value decay and placed attention SLA
  risk ahead of marginal task loss.
- Added a real `RECOVERY_CHECK_IN` action with evidence and one-slice override
  leases.
- Added chain-level feasibility admission before EDF placement and explicit
  overload reporting.
- Defined completion predicates and transition evidence for every action type.

## Iteration 4 — Evidence-safe lifecycle

### Proposal

The policy now installs only from a coherent, versioned snapshot, can
invalidate/reschedule accepted future work, admits complete feasible chains
before placement, and gives recovery uncertainty and every action transition
testable semantics.

### Reviewer critique

- Advisory workspace reservations and pause/cancel language could be
  misimplemented as external control, violating watcher-not-spawner.
- Overload admission could silently discard a user-accepted commitment.
- Action completion conflated an ended attempt with a successful outcome,
  losing failed/partial work and retaining stale reservations.
- Notification cooldown lacked typed severity, deduplication, snooze, and focus
  boundary guarantees.
- Unknown recovery could become a coercive recurring high-tier prompt.
- Learning only from completed work created survivor bias and could silently
  drift user preferences.

### Resolution

- Limited writes to app-owned state and direct clipboard actions; added a
  side-effect firewall, manual workspace preparation, and suggestion-only
  interactive starts.
- Added `unschedulable_conflict`, minimal conflict reporting, and explicit user
  resolution for incompatible accepted commitments.
- Split execution lifecycle from achieved/partial/failed/abandoned/unknown
  outcomes and added evidence reconciliation.
- Added a typed, rate-limited, fingerprinted delivery policy.
- Kept unknown recovery non-coercive with boundary-only check-ins and
  user-owned suppression leases.
- Included censored/failed attempts, restricted learning to estimative models,
  and required shadow replay before model promotion.

## Iteration 5 — Agency and side-effect containment

### Proposal

The policy is now structurally watcher-only, preserves conflicting user intent
for explicit resolution, learns from all attempts without learning preferences,
and delivers recommendations through a bounded notification policy.

### Reviewer critique

- Chain admission was a combinatorial optimization problem with no bounded,
  deterministic search or plan-level objective.
- Numeric focus-disruption cost lexicographically dominated arbitrarily large
  soft value loss.
- Saha planning was treated as if it could promise downstream execution before
  it revealed eligibility, resources, runtime, and review load.
- Provider quality/fallback lacked versioned capability, privacy, checkpoint,
  reliability, and rework semantics.
- Explanations were not mechanically tied to the actual decisive constraint.
- Rich local history lacked minimization, encryption, retention, deletion, and
  diagnostic-redaction rules.

### Resolution

- Added bounded deterministic branch-and-bound, a plan-level score, search
  completeness labeling, and exhaustive small-fixture validation.
- Replaced unbounded focus dominance with a bounded protected lease followed by
  net reviewed-value comparison.
- Made Saha work a conditional DAG with tentative option envelopes and
  replanning after planning/verification.
- Added route manifests, hard capability/data-policy floors, expected rework,
  and explicit checkpoint portability.
- Added structured decision traces as the only source for explanations.
- Added encrypted local data classes, minimization, retention, user deletion,
  redaction, and no-cloud defaults.

## Iteration 6 — Bounded optimization and conditional execution

### Proposal

The advisor now searches a bounded, deterministic set of complete conditional
plans, compares expected reviewed outcomes rather than quota alone, explains
from an auditable trace, and limits the lifetime and sensitivity of local data.

### Reviewer critique

- The plan score mixed minimizing/maximizing directions and incompatible units,
  making comparison and pruning undefined.
- Summed per-run p80 costs were not a calibrated joint batch bound under
  correlated provider/common-mode uncertainty.
- Expected value could favor unreliable, high-downside “lottery” routes.
- Saha verification preceded workspace creation even though readiness was bound
  to workspace/base identity.
- Failed attempts could re-enter an unbounded retry/quota-burn loop.
- Evaluation lacked baselines, calibration, adversarial/property tests, and
  quantitative rollout gates.

### Resolution

- Defined an oriented, fixed-point lexicographic plan vector, within-constraint
  scarcity normalization, and component-wise optimistic pruning bounds.
- Added an explicit overrun risk budget, joint/common-mode envelopes, union-bound
  fallback, and single-heavy-run cold-start rule.
- Added hard reliability/downside gates and risk-adjusted reviewed value.
- Split plan and launch-preflight attestations with exact invalidation scopes.
- Added failure lineage/classification, retry/cooldown limits, orphan
  reconciliation, and a typed repair action.
- Added calibration, exhaustive/regret, property/race, adversarial replay,
  baseline, and silent→passive→proactive gates.

## Iteration 7 — Risk-bounded planning and validation

### Proposal

The policy now has mathematically oriented plan comparison, joint capacity
risk, downside-limited provider routes, dual readiness attestations, bounded
failure recovery, and evidence gates for staged rollout.

### Reviewer critique

- Numerous thresholds had no versioned configuration schema, ownership,
  validation, migration, or rollback.
- A 24-hour horizon either rejected long chains or hid their later review/quota
  cost just beyond the edge.
- Top-K construction could starve old, cross-project, or small maintenance work
  indefinitely.
- Attention urgency trusted duplicate/stale/low-confidence PTY and hook
  observations too strongly.
- Controls were too narrow for pausing, pinning, exclusions, plan inspection,
  and “why not this task?”.
- The target system was too large for a viable first implementation with
  current adapters and evidence.

### Resolution

- Added a typed, hashed, atomic, reversible `PolicyProfile` with provenance and
  shadow diff.
- Added detailed-next-workday plus coarse-seven-day planning with terminal
  state and tail feasibility.
- Defined mandatory inputs and fair optional slots, deferral tracking, and
  explicit triage states.
- Added generational/TTL attention evidence reconciliation and restricted
  interrupts to fresh explicit evidence.
- Added global/card/route controls, inspectable per-node batch acceptance, and
  trace-backed “why not?”.
- Split the target into passive conservative Phase A, validated-adapter Phase B,
  and calibrated/proactive Phase C with exact missing-capability degradation.

## Iteration 8 — Governed, fair, and shippable policy

### Proposal

The policy now governs every threshold, accounts for costs beyond the detailed
horizon, prevents silent starvation, reconciles attention evidence, exposes
reversible user control, and separates the full target from a safe first
release.

### Reviewer critique

- Phase A allowed launch suggestions without the dual attestations and route
  manifests required by global invariants.
- Manual availability, preflight, provider, and recovery assertions lacked a
  common provenance/scope/expiry contract.
- Calendar hard boundaries lacked UTC/IANA, DST ambiguity, monotonic-duration,
  all-day, overlap, and clock-change semantics.
- The Saha DAG integrated before review and did not connect review disposition
  to realized value/completion.
- Arbitrary per-node acceptance could separate a launch from mandatory review
  and resource reservations.
- Recovery/provider override wording could turn unknown evidence or measured
  exhaustion into a fabricated known state.

### Resolution

- Added a short-lived, low-confidence manual Phase-A preflight attestation,
  static supported-route manifests, measured quota, and one resumable
  low-downside run while preserving every invariant.
- Added a common user-attested `ManualAssertion` with precedence, invalidation,
  reconfirmation, and trace wording.
- Defined UTC/IANA half-open boundaries, explicit profile zones, DST parsing,
  monotonic leases, busy unions, and clock/zone invalidation.
- Moved accepted review before integration, added post-integration verification,
  typed review dispositions, and acceptance-criteria value realization.
- Added atomic per-task commitment bundles and prerequisite-safe acceptance.
- Added an override matrix that never converts missing/exhausted evidence to
  known capacity.

## Iteration 9 — Consistent evidence, time, and commitments

### Proposal

Every phase now obeys the same invariants; manual evidence is explicitly
user-attested and expiring; time semantics survive DST/travel; reviewed value
precedes accepted integration; and launch commitments are atomic safety
bundles.

### Reviewer critique

- `PREPARE_BATCH` was simultaneously a timed action and a zero-duration UI
  group, while observed DAG phases were missing from the typed model.
- Phase A lacked a required future review-window assertion and an exact
  non-optimizer decision rule.
- Reviewed value could be realized/double-counted before post-integration
  verification; review debt mixed future obligation with spent effort.
- One high/medium/low label conflated evidence, feasibility, ranking, search,
  capability, and accepted risk.
- Decision-affecting adjectives and thresholds lacked a normative glossary,
  schema, default fixture, pure functions, and exact golden results.

### Resolution

- Split human actions, observed machine phases, reservation-only nodes, and
  zero-duration conditional groups; every node now declares resources,
  evidence, and cancellation.
- Required a Phase-A manual review-window assertion, defined the preflight sum
  type/static low-downside class, and added an exact eight-row decision table.
- Added an exactly-once criterion-revision value ledger with provisional value,
  post-integration realization, and separate spent effort/future debt.
- Replaced the scalar label with a six-dimensional confidence vector and
  action-specific projection.
- Added normative schemas, canonical profile thresholds, pure functions,
  glossary, and golden scenarios with an explicit authority order.

## Iteration 10 — Normative end-to-end contract

### Proposal

The final candidate policy has a coherent typed DAG, a safe and useful
first-release decision table, exactly-once reviewed value, decomposed
uncertainty, and machine-checkable contracts/defaults/golden outcomes.

### Reviewer critique

- The first schema left nested profiles unconstrained, forced groups into an
  execution lifecycle, omitted core candidate/node fields, and lacked schemas
  for several pure-function contracts.
- Golden fixtures were partial, missed DST/tie cases, and had no validation
  command.
- Phase A lacked an actual supported-route manifest and exact sub-order within
  decision-table rows.
- Launch bundles reserved review but not accepted integration and final
  verification effort.
- Confidence dimensions lacked deterministic projection rules and complete
  golden expectations.
- The iteration/status audit could not close until these proofs passed.

### Resolution

- Replaced the schema with constrained profile ranges/provenance overrides,
  discriminated node kinds, enumerated actions, and schemas for snapshots,
  attention, windows, candidates, gates, vectors, plans, search, transitions,
  value, preflight, traces, outputs, manifests, and the golden suite.
- Added nine complete input/output fixtures including DST and stable ties plus a
  local validator/exact-output comparison command.
- Added a versioned Phase-A Codex route manifest and exact row/sub-order/action
  precedence.
- Extended debt, assertions, bundles, and the launch fixture through review,
  accepted integration, and post-integration verification.
- Added deterministic confidence projection and full vectors to every golden
  recommendation.
- Validation passes:
  `contracts valid: profile, route manifest, 9 golden scenarios`.

### Final verification

The reviewer confirmed all six final contract blockers closed:

- constrained, discriminated schemas cover the core contracts;
- nine complete golden scenarios validate, including DST and stable ties;
- Phase A has a manifest and deterministic selection rules;
- bundles reserve review, integration, and post-verification effort;
- confidence projection is deterministic and fully represented;
- the normative validator passes.

**Reviewer verdict:** Approved—ready for user review.
