# Normative Algorithm Contracts v1

**Status:** Review
**Date:** 2026-07-04

This file removes decision-affecting ambiguity from
[task-description.md](../task-description.md). For identical versioned inputs,
implementations must return identical gates, priority vectors, plan/bundle
state, confidence vectors, and decision traces.

## Authority

Conflicts resolve in this order:

1. [contracts-v1.schema.json](contracts-v1.schema.json)
2. [policy-profile-v1.yaml](policy-profile-v1.yaml)
3. [phase-a-route-manifests-v1.yaml](phase-a-route-manifests-v1.yaml)
4. [golden-scenarios-v1.yaml](golden-scenarios-v1.yaml)
5. This glossary
6. The explanatory task description

Prose examples are non-normative.

## Glossary

| Term | Normative definition |
|---|---|
| `heavy_run` | Machine p80 is at least 60 minutes **or** `cost_upper` consumes at least 10% of any affected constraint's usable capacity. |
| `low_downside` | Static/validated manifest says resumable; acceptable-output probability meets the route floor; p95 repair plus review is at most 60 minutes; unattended-attention probability is at most 0.10; sunk quota is at most 10% of every affected constraint. |
| `material_change` | Any route/workspace/base/risk-class change, or duration/review-capacity delta greater than `max(10 minutes, 20% of the previously accepted value)`. |
| `short_gap` | Human window at least 5 and less than 25 minutes after buffers. |
| `qualifying_break` | At least 10 monotonic minutes with no recorded work, confirmed by the timer adapter or an explicit user assertion. |
| `protected_slice` | Current slice before the earliest of its checkpoint, hard boundary, Pomodoro boundary, or 25-minute continuity lease. |
| `fresh_attention` | Request evidence age at most 5 minutes, current session generation, unresolved, and not contradicted. |
| `high_confidence_attention` | Explicit prompt evidence from a validated source or a user-marked request; inferred waiting state is never high confidence. |
| `high_value` | UI shorthand only for user priority at least 80/100. Core comparisons use the integer value, never the label. |
| `confidence_adjusted_reserve` | Per constraint: `max(10% of usable capacity, q95 absolute capacity-source error)`; if error is unavailable, use 25%. |
| `review_debt` | Sum of upper-bound future human review/re-review obligations; excludes already-spent review effort. |
| `substantial_duration_change` | Alias of the duration branch of `material_change`; no separate threshold. |
| `manual_attestation_fresh` | Not expired and no scoped route/workspace/base/credential/config/source-generation field has changed. |
| `search_limited` | Search stopped at the configured expansion bound with at least one live branch whose optimistic vector could beat the incumbent. |

## Pure functions

All functions receive `now`, IDs, source versions, and the policy profile
explicitly; none read wall clock, environment, network, or global mutable state.

```text
assemble_snapshot(source_readings, ledger_revision, now) -> SnapshotEnvelope
reconcile_attention(events, session_generations, now, profile) -> [AttentionRequestEvidence]
build_windows(snapshot, profile) -> HumanMachineWindows
enumerate_candidates(snapshot, windows, profile) -> [Candidate]
apply_hard_gates(candidate, snapshot, profile) -> GateResult
priority_vector(candidate, snapshot, profile) -> PriorityVector
compose_bundle(candidate_chain, reservations) -> CommitmentBundle
phase_a_select(eligible_candidates, snapshot, profile) -> Plan
bounded_search(chains, incumbent, profile) -> SearchResult
transition(node, evidence, now, profile) -> TransitionResult
confidence_vector(decision_trace, capability_registry) -> ConfidenceVector
render_recommendation(decision_trace, confidence) -> RecommendationOutput
```

Candidate enumeration and every tie use stable ascending IDs after the
documented policy keys. Arithmetic is saturating signed 64-bit fixed point.
The canonical profile marks every base field `system_default`; any changed
field is represented by one `field_overrides` entry with its JSON-pointer path,
typed value, and `user_set` or `learned_estimate` provenance.

## Confidence projection

Projection is deterministic:

1. `evidence_quality` is the weakest decisive evidence in this order:
   `validated_measured > measured > user_attested > estimated > unknown`.
2. `feasibility_risk` is:
   - `unproven` if any hard feasibility input is unknown or stale;
   - `risk_accepted` if an allowed scoped uncertainty override is decisive;
   - `calibrated_bounded` if all decisive bounds are validated and calibrated;
   - otherwise `conservative_static` when all gates pass using canonical static
     upper bounds.
3. `ranking_confidence` is:
   - `calibrated` only for a promoted Phase-C model/search;
   - `heuristic` for bounded search or Phase-B policy;
   - `baseline_only` for Phase A or disabled search.
4. `search_completeness` is copied exactly from the selector:
   `complete | limited | disabled`.
5. `capability_phase` is copied from the active capability registry.
6. `risk_accepted` is the decisive override ID, otherwise `false`.
7. `downgrade_reasons` is the stable sorted list of decisive inputs that
   produced a weaker-than-best dimension.

Decisive evidence by action:

| Action | Evidence set |
|---|---|
| Launch bundle | both attestations, route manifest, every quota constraint, workspace/resource state, operator availability, completion-window assertion/calendar, duration/cost/reliability bounds |
| Focus/planning | operator availability, known calendar boundaries, slice duration/checkpoint data, protected lease |
| Respond | attention evidence, response bound, SLA, current slice/boundary |
| Rest/check-in | recovery evidence or assertion, lease, hard boundary |
| Review/integrate/verify | output/criterion revision, workspace state, completion window, duration bound |

User-attested evidence remains `user_attested` even when repeatedly confirmed.
Limited search changes ranking/search only; it does not downgrade independently
bounded feasibility.

## Required golden coverage

The golden scenarios cover:

- meeting-fragmented time chooses bounded admin/recovery, not a new focus task;
- low-confidence stale attention cannot interrupt a protected slice;
- missing Phase-A review-window assertion blocks launch but permits planning;
- a fully attested Phase-A single launch creates one atomic commitment bundle;
- evidence-supported recovery due selects rest before work;
- an unknown or exhausted provider constraint never becomes feasible through
  an availability override;
- review value remains provisional until post-integration verification;
- a DST fold/gap produces one unambiguous UTC plan;
- equal candidates resolve by deadline, action precedence, card ID, route ID.

## Implementation conformance

Validate the normative package:

```sh
ruby docs/tasks/task-06-proactive-mission-control/research/validate-contracts.rb
```

Pass an implementation result YAML as the first argument to compare every
`actual` plan/trace/recommendation against the golden `expected` output.

Conformance requires:

1. schema validation of fixtures and emitted artifacts;
2. exact golden output equality;
3. property tests for no double booking, exactly-once value realization,
   bundle atomicity, and legal lifecycle transitions;
4. replay determinism across process restarts;
5. zero side effects outside the app-owned store and direct clipboard action.
