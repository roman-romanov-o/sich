# Task Description: Proactive Mission-Control Policy

**Status:** Review
**Last Updated:** 2026-07-04

## 1. Purpose

Ghostling should answer a more useful question than “what is running?”:

> Given my commitments, focus state, task readiness, active agents, and separate
> provider limits, what is the best thing for me to do now—and what should I
> prepare for the next unattended work window?

The policy is a local, explainable, receding-horizon advisor. It coordinates:

- **Saha/autonomous flow:** plan, verify, manually launch, run in the
  background, then review.
- **Interactive flow:** one human-attended agent session at a time.
- **Human recovery:** focus blocks, breaks, working hours, and meeting buffers.
- **Machine capacity:** concurrent agents and non-fungible provider pools.

It proactively recommends actions but never executes a command, answers an
agent prompt, edits a calendar, or controls the Pomodoro timer.

## 2. Goals

- Recommend one concrete **now action** and, when useful, a short **next plan**.
- Protect focused work from low-value interruptions and short calendar gaps.
- Use unattended periods for verified Saha work without creating unreviewable
  output.
- Route eligible work across Claude interactive, Claude Agent SDK, Codex, and
  Gemini without summing their limits.
- Make breaks and stopping work first-class valid recommendations.
- Explain every recommendation with the decisive constraints and uncertainty.
- Learn duration and quota-cost distributions from observed outcomes while
  remaining useful during cold start.

## 3. Non-goals

- Automatically dispatching, resuming, or responding to agents.
- Replacing Saha planning, verification, or execution.
- Maximizing quota consumption, agent count, keyboard activity, or hours worked.
- Reading calendar event content by default or scraping communication content.
- Diagnosing health, mood, or cognitive ability from passive behavior.
- Building a globally optimal long-range scheduler in v1.

## 4. Optimization contract

The policy uses a **lexicographic objective**, in this order:

1. Respect explicit commitments, working-hour limits, and recovery constraints.
2. Avoid dropped human-attention requests and prevent urgent blockers.
3. Preserve useful focus and minimize unnecessary context switches.
4. Maximize reviewed, high-value task progress—not raw agent starts.
5. Exploit otherwise-idle autonomous capacity and provider headroom.

A lower objective can never compensate for violating a higher one. In
particular, spare quota cannot justify skipping a needed break or colliding with
a meeting.

## 5. Safety and product invariants

1. **Suggest only.** Commands are displayed or copied; no recommendation path
   invokes them.
2. **One foreground thread.** At most one action may consume the operator's
   focused attention at a time.
3. **Saha readiness gate.** Autonomous execution is eligible only when the task
   has both a current plan attestation and launch-preflight attestation.
4. **Separate pools.** Capacity is reserved and evaluated independently for
   every provider/pool.
5. **Review is part of completion.** Autonomous work may be launched only when
   its expected review load fits the configured review-debt budget.
6. **Calendar is a hard boundary.** Focus work must fit before the next busy
   interval with setup/wrap buffers.
7. **Recovery is a real action.** When the configured recovery limit is reached,
   work actions are temporarily ineligible unless the user explicitly overrides.
8. **Unknown stays unknown.** Missing calendar, effort, duration, or quota data
   lowers confidence and activates conservative fallbacks; it is never replaced
   by a fabricated zero.
9. **Stable advice.** A recommendation changes only after material new evidence,
   expiry, or a decision boundary.
10. **Watcher-only side effects.** Ghostling writes only its app-owned
    plan/feedback store and the clipboard after a direct user copy action. It
    never creates worktrees/branches, acquires external locks, starts/stops
    processes, pauses/cancels sessions, answers prompts, controls a timer, or
    edits a calendar.

### 5.1 Governed policy profile

All tunable policy is a versioned `PolicyProfile`. Every field has a type,
unit, legal range, default, and provenance:
`system_default | user_set | learned_estimate`. It includes risk budgets,
reliability floors, review/concurrency caps, attention SLAs, soft value-decay
functions, buffers, leases, retry/cooldown rules, notification limits, search
bounds, retention, and rollout thresholds.

Non-overridable invariants in §5 are not profile fields. User preferences are
never learned estimates, and estimative parameters cannot change preferences.
Snapshots, plans, traces, and model outputs store `policy_profile_hash`.

A profile is schema-validated and activated atomically. Material edits show a
diff plus shadow projection of changed recommendations before activation.
Schema migration and one-click rollback retain the prior valid profile. A
profile change replans accepted future work while preserving user intent unless
a hard gate becomes invalid.

All phases and degraded modes obey every invariant in §5 unchanged.

## 6. Input snapshot

The advisor evaluates an immutable snapshot at time `now`.

### 6.1 Operator and time

- Time zone, working hours, quiet hours, and manual “done for today” state.
- Current foreground card, current focus phase, and focus time since the last
  completed restorative break.
- User-configured focus, short-break, long-break, meeting-buffer, and shutdown
  preferences.
- Optional explicit energy check-in: `low | normal | high`. The system does not
  infer energy from typing or app activity.
- Last time at which recovery state was supported by complete evidence, and any
  active recovery check-in/override lease.

### 6.2 Calendar

- Free/busy intervals over the lookahead horizon.
- Event start/end and optional user-marked flexibility.
- Operator-available intervals in which a manual launch or decision can occur,
  plus the last manual-launch deadline before each absence.
- Device, network, runner, and provider availability intervals, including
  machine blackout/maintenance periods.
- Calendar freshness and permission state.

Only free/busy data is required. Titles, attendees, and descriptions are not
part of the default contract.

All calendar and quota boundaries are UTC instants carrying their source IANA
time zone; windows are half-open `[start, end)`. Working hours follow the
explicit profile zone (default: current device zone until the user chooses).
Manual local times require a zone and an explicit earlier/later choice when DST
is ambiguous. Monotonic time measures elapsed work, leases, and cooldowns;
wall-clock instants define meetings and resets. All-day events are busy by
default; overlapping calendars and busy intervals are unioned. Zone or
system-clock changes invalidate and rebuild affected plans.

#### Manual assertions

Every manual input uses:

`ManualAssertion = {kind, value, scope, entered_at, effective_interval,`
`                   timezone, expires_at, confidence=user_attested}`

This covers free-until/absence, event flexibility, workspace/preflight,
provider scheduling availability, and recovery responses. It is never labeled
measured. Known busy intervals narrow manual availability unless the user adds
an explicit event-scoped flexibility override. Changes to route, workspace,
base, credentials, or session/source generation invalidate the corresponding
preflight assertion. Decisive assertions are reconfirmed immediately before
launch, and explanations say “you reported…” rather than “calendar is free.”

### 6.3 Work cards

Each card supplies:

- value/priority, deadline, dependencies, and current lifecycle/state;
- recommendation state:
  `eligible | pinned_next | defer_until | archived | never_auto_recommend`,
  plus deferral count and last-considered time;
- flow eligibility: `saha`, `interactive`, or both;
- Saha planning and verification state;
- `PlanAttestation`: hashes/versions of planning artifacts, acceptance
  criteria, declared dependencies, task revision, and verifier version;
- `LaunchPreflightAttestation`: observed workspace identity/base commit,
  route-manifest version, tools, credentials, and execution configuration;
- eligible provider routes and minimum provider-quality constraints;
- a versioned route manifest per provider/model: capabilities/tools, data
  policy, checkpoint format/portability, historical success probability, and
  expected repair/review load;
- distributions for human setup/planning/review time, machine run time, and
  route-specific quota cost;
- human slicing data: minimum useful slice, recommended slice, checkpoint/wrap
  cost, latest safe stop, and whether the action is preemptible;
- machine interruption mode: resumable, safely pausable, or must finish;
- machine-resource claims: repository, worktree, branch, base commit, exclusive
  environments, ports/services, and shared test targets;
- integration order and expected merge/integration review time;
- attempt lineage, retry count, failure fingerprint/class, checkpoint, and sunk
  human/quota cost;
- current human-attention request, its age, expected response time, urgency, and
  number of agents it unblocks;
- confidence and freshness for each field.

Durations and costs are distributions (`p50`, `p80`), not single promises.

### 6.4 Live machine state

- Running, waiting, blocked, reviewing, and completed sessions.
- Provider and pool consumed by each live session.
- Current autonomous concurrency by provider and globally.
- Reserved quota for live work and its predicted remaining cost.
- Workspace/resource leases and unattended-run preflight state.

Attention is carried as `AttentionRequestEvidence`: request ID, session
generation, prompt fingerprint, source event IDs, observed time, TTL,
confidence, and resolution state. Response duration and unblock leverage stay
unknown unless supported by explicit evidence.

### 6.5 Plan and reservation ledger

Every policy pass reads the current persisted plan ledger:

- stable `plan_id`, `logical_node_id`, `attempt_id`, `reservation_id`,
  prerequisite edges, and policy version. Logical identity excludes its
  scheduled window; attempts and reservations can move without duplicating the
  logical action;
- node status:
  `proposed | accepted | observed_started | completed | blocked | invalidated |
  unschedulable_conflict | failed | cancelled | expired`;
- attempt execution:
  `not_started | running | ended`, independently of outcome:
  `achieved | partial | failed | abandoned | unknown`;
- reservation status: `tentative | firm`;
- human-window, machine-resource, provider-capacity, and review reservations;
- `CommitmentBundle` identity for safety-coupled launch, machine
  resource/quota, integration ordering, and review-capacity nodes;
- supersession relationship to a newer plan.
- transition evidence IDs, source versions, timestamps, and reason codes.

Accepted nodes and all unexpired reservations participate in subsequent
feasibility checks. Replanning atomically installs the replacement plan and
releases only superseded tentative reservations. Firm reservations remain until
their node completes, is cancelled, expires, or a changed hard constraint
atomically invalidates/reschedules the future attempt. An already-started node
remains an observed fact; the advisor may recommend a safe human pause/cancel
action rather than rewriting history.

### 6.6 Capacity and effort

- Independent quota constraints, reset/refill rules, source freshness, and
  confidence. A pool can have several simultaneous constraints.
- Completed Pomodoro **work** events attributed to cards where known. The
  currently accepted effort-log contract does not record breaks or live phase.
- Observed terminal work and completed task outcomes.

The existing append-only Pomodoro effort log remains read-only. A future
read-only timer adapter may expose current phase and the last confirmed
restorative break; the advisor does not control it.

### 6.7 Snapshot envelope

All inputs are assembled into:

`SnapshotEnvelope = {snapshot_id, source_versions, observed_at, valid_until}`

Every candidate records the decisive source versions it used. A snapshot is
installable only while those sources and the plan-ledger revision still match.

## 7. Plan-node model

`HumanAdvisoryAction` candidates may reserve operator attention:

| Action | Human attention | Machine use | Typical outcome |
|---|---:|---:|---|
| `REST` | none | none | recover before more focused work |
| `RECOVERY_CHECK_IN` | brief | none | establish recovery state without pretending to know it |
| `SHUT_DOWN` | low | none | stop for the day |
| `CONTINUE(card)` | focused | existing | preserve current context |
| `RESPOND(card)` | brief/focused | unblocks existing | clear an agent request |
| `REVIEW(card)` | focused | none | convert agent output into accepted progress |
| `PLAN_SAHA(card)` | focused | none | move a task toward verified readiness |
| `PLAN_VERIFY(card)` | brief/focused | none | obtain the plan attestation |
| `SUGGEST_LAUNCH(card, route)` | brief | new background | reveal/copy a launch command |
| `PREPARE_WORKSPACE(card)` | focused | none | ask the user to create/confirm required isolation |
| `LAUNCH_PREFLIGHT(card, route)` | brief | none | obtain the workspace/route attestation |
| `RECONCILE_FAILURE(card)` | focused | none | inspect and resolve an ended/orphaned attempt before retry |
| `SUGGEST_INTERACTIVE_START(card, route)` | focused | new foreground | reveal how to begin hands-on work |
| `SUGGEST_INTEGRATION(card)` | focused | none | reveal the reviewed integration step |
| `POST_INTEGRATION_VERIFY(card)` | focused | none | run/inspect required final checks |
| `SMALL_ADMIN(card)` | light | none | use a fragmented calendar gap |

Every candidate includes:

- `human_p50`, `human_p80`, `machine_p50`, `machine_p80`;
- earliest start, deadline, and expiry;
- provider route and quota-cost `p80`, when applicable;
- expected value, unblock leverage, continuity bonus, switch cost;
- review load created;
- confidence and missing-input reasons.

Other node kinds are not advisory actions:

| Node kind | Resources | Transition evidence | Cancellation |
|---|---|---|---|
| `ObservedMachinePhase` (`RUN`, candidate integration, accepted integration, verification) | observed workspace/provider/lease | matching session/output/revision events | never controlled by Ghostling; observed end/failure only |
| `ReservationOnly` | human window, quota, workspace, review, or integration order | owning bundle/node state | released on expiry, invalidation, or bundle cancellation |
| `ConditionalGroup` (`PREPARE_BATCH`) | none; zero duration | child summaries only | removing it never changes child state |

Groups have no execution/outcome lifecycle and cannot reserve resources. Every
DAG node has exactly one kind, declared resources, transition predicate, and
cancellation behavior.

## 8. Receding-horizon policy

### 8.1 Triggers and horizon

Recompute on:

- card/session state transition;
- a new or resolved attention request;
- focus/break phase completion;
- calendar or quota change;
- recommendation expiry;
- any decisive source freshness/TTL expiry, even without a new event;
- user override, snooze, or explicit refresh.

The lookahead has two resolutions:

- **Detailed:** exact windows through the end of the next working day.
- **Coarse tail:** aggregate capacity through relevant task deadlines and quota
  resets, capped at seven days.

The tail carries unfinished runs, expected review debt, quota reservations,
workspace occupation, and dependency state. Admission requires tail
feasibility, but never claims precise calendar fit beyond calendar freshness;
it uses conservative aggregate human/machine capacity envelopes. Every trigger
replans from current evidence.

Recommendation expiry is no later than the earliest decisive input's
`valid_until`.

### 8.2 Build opportunity windows

Build two independent timelines:

`HumanWindow = working_hours ∩ operator_available − busy − meeting_buffers`

`MachineWindow = device/network/runner/provider availability − machine_blackouts`

1. Split each timeline into contiguous windows.
2. Label human windows `focus`, `brief`, `recovery`, or `off_hours`.
3. Label machine intervals overlapping operator absence as `unattended`.
4. Link a human launch node to its machine-run node with a prerequisite edge;
   meetings and human absence do not remove machine capacity.
5. Attach a manual-launch deadline to the last human window before each
   unattended machine window.
6. Reserve hard calendar commitments and already-started work first.
7. Run the bounded plan search in §8.11. Admit only a feasible subset of
   remaining action chains and report every unsatisfied commitment.
8. Admit an autonomous launch only when its complete dependent chain—manual
   launch, machine run/resources/quota, integration, and review—fits.
9. Place admitted human nodes without overlap using deterministic
   earliest-deadline-first scheduling. EDF places admitted work; it does not
   decide overload admission.
10. Record confidence. Free/busy alone does not prove operator availability. If
   availability is missing, do not create an unattended launch plan. If
   calendar data is unavailable or stale, do not claim a window is
   meeting-free.

If accepted commitments become mutually infeasible, mark the set
`unschedulable_conflict` without cancelling or rejecting the user's acceptance.
Compute the minimal conflicting set and binding resource/time, admit no new
lower-priority chain on that resource, and offer explicit resolutions:
move, shorten, cancel, or user-authorized override. Only the user's chosen
resolution mutates accepted intent.

### 8.3 Compute human state

Recovery evidence is separately modeled as
`known_due | known_not_due | unknown`. `known_due` and `known_not_due` require a
complete evidence interval since a qualifying break, or an explicit user
check-in. A current phase or work-only history cannot prove either state.

Human state is one of:

- `recover_now`: recovery limit reached or an explicit break phase is active;
- `focus_active`: a foreground action is in progress;
- `focus_available`: a focus window is open;
- `fragmented`: only a brief window remains;
- `shutdown`: outside hours or explicitly done for the day.

When recovery evidence is `unknown`, the policy reports “recovery state
unknown” and offers a low-confidence break/check-in. It does not apply the hard
recovery gate or claim that the configured limit was reached.

After `max_unknown_recovery_interval` (v1 default: 120 minutes), the advisor
offers `RECOVERY_CHECK_IN` once at the next focus boundary. Unknown recovery is
never a known violation and never interrupts mid-focus. Responses have explicit
semantics:

- `rested` → `known_not_due` for one configured evidence lease;
- `needs_break` → `known_due` until a qualifying break is confirmed;
- `skip_once` → a user-owned snooze lease while uncertainty remains visible;
- `pause prompts` / `dismiss today` → suppress further unknown-state prompts
  for the selected interval.

Unknown-state delivery is limited to one passive/boundary prompt per lease.
Hard `REST` applies only to evidence-supported `known_due`.

### 8.4 Handle attention without destroying focus

Reconcile hook, PTY, and transcript observations by request ID, session
generation, and prompt fingerprint. Deduplicate them into one request; expire
by TTL; invalidate on session-generation change or contradictory current
state; retain source evidence for replay.

For each waiting/blocked card, calculate:

`interrupt_value = urgency + unblock_leverage + age_risk - response_cost - switch_cost`

Interrupt the current focus action only when:

- a fresh, high-confidence explicit/user-marked request is deadline-critical; or
- it is brief, unblocks high-value work, and exceeds the configured interrupt
  threshold.

Unknown response duration or unblock leverage receives an uncertainty penalty,
not a fabricated zero. Low-confidence waiting/blocked evidence is passive or
boundary-only and cannot interrupt.

Otherwise queue it for the next focus/Pomodoro boundary and say so explicitly,
for example: “Two agents are waiting; defer both for 18 minutes to preserve the
current block.”

### 8.5 Reserve review capacity

Before proposing new autonomous work:

1. Sum `p80` review time for completed-unreviewed work.
2. Add `p80` review time expected from live autonomous runs.
3. Add the candidate's expected review time.
4. Locate focus/brief windows in which that review can occur before its
   deadline.

Reject the launch when the review cannot fit or when total review debt exceeds
the configured cap. Planning may still be recommended because it creates
launch-ready inventory without creating review debt.

When review debt is at or above the cap, any action that increases it or
materially delays a deadline-bound review is ineligible until the debt drops.

Reviewed value uses an exactly-once `ValueLedger` keyed by immutable
`(card_id, acceptance_criterion_id, criterion_revision)`:

- `forecast`: expected but not reviewed;
- `provisionally_accepted`: accepted in review but awaiting required
  integration verification;
- `realized`: post-integration verification passed;
- `revoked`: later authoritative evidence invalidated the accepted revision.

Card value is explicitly allocated across criterion revisions; partial
acceptance affects only those criteria. A changed criterion receives a new
revision and supersession link, so repair cannot credit the same revision
twice. `changes_requested` consumes the completed review reservation, records
spent review effort, then creates separate estimated repair and re-review
obligations. Review debt means all outstanding future human completion
obligation—review, accepted integration, and post-integration
verification—never historical effort.

### 8.6 Route provider capacity

Each provider pool is a vector of independently enforced constraints:

`QuotaConstraint = {unit, available_capacity(t), breakpoints, confidence}`

For example, an interactive pool may expose both rolling-window and weekly
constraints. Route cost must be expressed in the same unit for every affected
constraint. `available_capacity(t)` is a deterministic function derived from
usage history plus reset/refill rules. Its breakpoints are launches, recorded
usage expirations, refills/resets, and horizon end.

Every candidate and live run supplies a cumulative
`cost_upper(elapsed, alpha)` envelope in the same unit. Admission has an
explicit capacity-overrun risk budget `alpha` (stricter for unattended and
must-finish chains) and uses a lower confidence envelope for capacity.

Common-mode provider/model/task-class uncertainty is modeled separately from
per-run error. When a calibrated joint envelope is unavailable, allocate
per-run tail budgets by union bound (`alpha_i = alpha / n`) and sum those upper
quantiles; if those quantiles are unavailable, use hard observed maxima. During
cold start, charge the entire upper cost at launch and allow at most one heavy
unattended run per uncertain pool. Calibration measures group overrun, not only
individual-run coverage.

For every eligible `(card, route)` pair:

1. Reject routes below the task's quality/capability requirement.
2. Read that route's pool and all of its constraints independently.
3. Project each constraint at candidate start, every capacity/cost breakpoint,
   and completion.
4. Reserve the joint upper cost envelope for live runs in each compatible unit.
5. Keep a confidence-adjusted safety reserve per constraint.
6. Reject the route if any affected constraint violates:

   `capacity_lower(t) - joint_cost_upper(t, alpha) < safety_reserve`

   Reject it as incomparable if remaining capacity and candidate cost do not
   share a defensible unit.
7. Estimate scarcity independently for each constraint before its reset:

   `scarcity = eligible_demand_upper_before_reset / usable_remaining`

8. Prefer the feasible route with the lowest opportunity cost, considering the
   route's worst binding constraint and:
   - scarcity for tasks that have fewer route choices;
   - quota likely to expire unused before reset;
   - preserving interactive capacity for upcoming interactive-only work;
   - provider concurrency and reliability;
   - route confidence.

User-declared capability, quality, and data-policy floors are hard gates.
Route-class risk limits are also hard gates:

- minimum probability of acceptable output;
- maximum p80/p95 repair and review load;
- maximum probability of an unattended attention request;
- maximum downside/sunk quota.

Unattended and must-finish work use stricter configured floors. Expected value
cannot compensate for these limits or for review-debt, privacy, quality, or
recovery gates.

Among routes that pass, compare expected **reviewed** value after predicted
failure, repair, extra review cost, and a configured downside/CVaR penalty—not
quota alone. Cross-provider
continuation is eligible only when an observed checkpoint is portable and the
target route manifest is compatible. Otherwise suggest a same-route resume or
an explicit restart that surfaces sunk work. Confirmation may accept quota
uncertainty, but never silently bypass capability, privacy, or quality floors.

Pools and their constraints are never added or collapsed to a single current
gauge. Unknown or incomparable capacity is ineligible for heavy new work by
default, but the UI may show a low-confidence alternative requiring explicit
user confirmation. Such a node is `risk_accepted`; it never becomes
high-confidence or supports a must-finish unattended guarantee.

### 8.7 Prepare unattended work

Each Saha task is a conditional DAG:

`PLAN → PLAN_VERIFY → PREPARE_WORKSPACE → LAUNCH_PREFLIGHT`
`     → SUGGEST_LAUNCH → RUN → REVIEW`
`     → [accepted] INTEGRATE → POST_INTEGRATION_VERIFY → DONE`

Every edge records branch predicates and assumptions. `PREPARE_BATCH` is only a
UI grouping of independent per-card planning nodes, not an atomic action or a
promise that every downstream branch will become feasible.

For each upcoming unattended window:

1. Estimate background capacity by provider and global concurrency.
2. Require a current `PlanAttestation`. Planning artifacts, acceptance
   criteria, declared dependencies, task revision, or verifier-version changes
   invalidate it and produce `PLAN_VERIFY`.
3. Require an **observed** isolated worktree/branch or external workspace lock.
   Ghostling's reservation is advisory and never creates/acquires the external
   resource. If isolation is missing, generate `PREPARE_WORKSPACE`. Reject batch
   combinations with overlapping exclusive environments, ports, services, or
   incompatible shared test targets.
4. Require a current `LaunchPreflightAttestation` after workspace preparation.
   Workspace/base, route manifest, tools, credentials, or execution config
   changes invalidate only preflight and produce `LAUNCH_PREFLIGHT`.
5. Select tasks whose machine `p80` fits the useful portion of the window, or
   whose declared interruption mode has a safe resume/pause path.
6. Reserve route capacity plus merge/integration ordering and later review
   capacity. Before verification, downstream reservations are tentative,
   visibly conditional option envelopes.
7. Back-schedule missing planning/verification/preflight into earlier human
   windows.
8. Back-schedule each `SUGGEST_LAUNCH` before absence. Compute:

   `launch_deadline = absence_start - launch_p80`
   `                  - stabilization_buffer - recovery_buffer`

9. Replace simple process liveness with `unattended_ready`, requiring successful
   preflight, correct workspace/base, no unresolved prompt, runner heartbeat,
   and a full stabilization interval.
10. Count unattended capacity only after `unattended_ready`. If readiness is
   absent at the deadline, expire that run and recommend repair/cancellation
   while the operator is still present.
11. Recommend a bounded batch; never exceed concurrency, resource, quota, or
    review-debt limits.

Neither attestation claims provider quality, runtime, quota cost, or future
output correctness; those remain separate risk estimates.

Integration before review is allowed only in an isolated candidate workspace
when required for testing; it is not accepted integration. Review disposition
is `accepted_done | accepted_partial | changes_requested | discarded |
unknown`. Accepted criteria become provisional; value becomes realized only
after required post-integration verification. `changes_requested` consumes the
finished review obligation and creates new repair/re-review obligations;
`discarded` records sunk cost and zero completed value. A task is complete only
after accepted review and required post-integration verification.

Recompute after every planning/verification outcome and immediately release or
reshape conditional envelopes when assumptions change.

This produces compound advice such as:

> Now: plan tasks A and B in the next 55 minutes. If each verifies with its
> current route, workspace, runtime, and review assumptions, prepare its launch
> before leaving. Replanning after verification will confirm the actual batch.

“Later” is a reminder/recommendation, not scheduled execution.

### 8.8 Select the now action

First apply hard eligibility gates: working-hour/shutdown state, known recovery
state, calendar fit, current plan/preflight attestations, quota constraints,
concurrency, review debt, dependencies, and provider capability.

Calendar fit is evaluated against the proposed attention slice:

- preemptible work must fit `recommended_slice + checkpoint_cost + wrap_time`,
  but may fall back as low as `min_useful_slice`;
- non-preemptible work must fit its full `p80 + wrap_time`;
- every slice has a `latest_stop` and bounded recheck time;
- machine work uses its declared resumable/pausable/must-finish semantics.

Order eligible candidates by a typed, comparable `PriorityVector`:

1. `hard_risk`: hard calendar/working-hours or evidence-supported recovery
   state: `violation_imminent | protected | none`.
2. `attention_sla_risk`: `breached | at_risk | safe | none`.
3. `focus_protection`: `protected | open`.
4. `net_marginal_outcome`: fixed-point expected reviewed value after delay,
   switch/checkpoint cost, failure, rework, and soft value decay.
5. `background_leverage`: versioned fixed-point value.
6. `resource_cost`: provider opportunity cost plus uncertainty penalty.

Hard-commitment or attention-SLA slack is:

`slack = deadline - now - scheduled_human_p80 - wrap - safety_buffer`

- `breached`: deadline is at or before `now`;
- `at_risk`: deadline is future and `slack <= 0`;
- `safe`: deadline exists and `slack > 0`;
- `none`: no deadline.

Only user-declared calendar/working-hour boundaries are hard commitments.
Ordinary task deadlines are soft targets represented by a declared,
fixed-point value-decay function. An overdue soft task cannot dominate forever:
it ranks by the additional value lost during the proposed delay. Attention uses
a configured SLA; user-marked critical requests have zero slack. A delay is
“material” only when it worsens a hard/attention risk class, breaches review
debt, crosses a hard boundary, or outlives the candidate's lease.

Typed recovery actions have explicit vectors:

- `REST` is `violation_imminent` when recovery is `known_due`;
- `RECOVERY_CHECK_IN` remains a boundary action when the unknown-evidence
  interval expires; unknown never becomes a hard violation;
- `SHUT_DOWN` is `violation_imminent` outside hard working hours or after an
  explicit done-for-day state.

The v1 continuity lease lasts until the earliest of the current slice end,
Pomodoro boundary, hard boundary, or configured `continuity_lease` (default
25 minutes). It is never renewed without a fresh comparison against the full
priority vector. During the lease, the current slice is `protected` unless a
higher hard/attention class intervenes. At expiry, all candidates are `open`
and switch cost is included only in `net_marginal_outcome` or a tie-break; it
cannot dominate arbitrarily valuable work forever.

Fixed-point weighted terms may break ties only within identical ordinal
classes:

`tie_break = urgency + unblock + continuity + fit + background_leverage`
`            - switch_cost - review_debt_added - quota_cost - uncertainty`

The final stable tie-break order is deadline timestamp, action-type precedence,
card ID, then route ID. Every `CONTINUE` recommendation has an expiry/recheck
time. It loses eligibility
when it would materially delay a higher-class deadline or capped review debt.
If no candidate honestly fits, choose `REST` or ask the user to select from
explicitly low-confidence options.

### 8.9 Persist and replace the plan

The selected output is a plan DAG, not an untracked list:

1. Assign `logical_node_id` from `(card, action type, attestation revisions,
   route, prerequisite purpose)`; assign separate attempt/reservation IDs to a
   scheduled window.
2. Carry forward accepted/started nodes and their firm reservations.
3. Schedule tentative nodes around them with earliest-deadline-first allocation.
4. Compare the new plan to the old plan by node identity.
5. Compare-and-swap against both ledger revision and all decisive source
   versions. Abort and recompute if either changed.
6. Atomically mark removed tentative nodes superseded, release their
   reservations, then install the replacement.
7. Promote a reservation to firm only after explicit acceptance or observed
   start.
8. Immediately before acceptance, command copy, or reservation promotion,
   revalidate decisive sources and hard constraints.
9. When hard evidence changes, mark affected future attempts
   `invalidated`/`blocked`, atomically release or migrate reservations, and
   re-run admission. Preserve the logical node if only its window moves.
10. Expire unaccepted launch nodes at their manual deadline and cascade
   cancellation to dependent machine/review nodes.

Thus replanning cannot double-book a human window, workspace, or quota
reservation, and “only the first action is committed” means only accepted or
observed nodes are firm—not that future reservations are forgotten.

### 8.10 Evidence-driven transitions

Execution ending and outcome success are independent. When an attempt ends,
release its elapsed human reservation and record effort even if the outcome is
partial, failed, abandoned, or unknown. Failed/partial outcomes generate
repair/retry candidates instead of remaining pending.

Authoritative outcome predicates include:

- `SUGGEST_LAUNCH`: copy/accept is an ended advisory attempt, not achievement;
  `achieved` requires a matching observed session with route, workspace, and
  both current attestation revisions.
- `PLAN_SAHA`: `achieved` means expected planning artifacts exist; each
  per-card `PLAN_VERIFY` and `LAUNCH_PREFLIGHT` has its own
  pass/fail attestation outcome.
- `RESPOND`: `achieved` requires the specific attention-request ID to resolve;
  an explicit stop can end the attempt with unknown/partial outcome.
- `REVIEW`: a typed disposition ends the attempt; only accepted criteria
  realize value, while changes/discard produce repair or sunk-cost outcomes.
- `POST_INTEGRATION_VERIFY`: required checks against the accepted integrated
  revision must pass before `DONE`.
- `REST`: `achieved` requires qualifying timer evidence or confirmation;
  interruption is ended/partial.
- `RECOVERY_CHECK_IN`: a defined response ends the attempt.
- `CONTINUE` / `SUGGEST_INTERACTIVE_START`: checkpoint reached, interruption,
  or explicit stop ends the bounded attempt and records the observed outcome.
- `PREPARE_WORKSPACE` / `SMALL_ADMIN`: achievement requires the declared
  observable result; explicit stop/failure still ends the attempt.
- `SHUT_DOWN`: the explicit done state or workday boundary is observed.

Every transition stores evidence IDs, versions, actual effort, resulting
revision, failure reason, and timestamps. A timeout creates a reconciliation
item: the user may attach evidence or mark the attempt
partial/failed/abandoned/unknown. If a prerequisite is invalidated, unstarted
dependents become `blocked` or `invalidated` and release tentative reservations.
Started dependents remain facts; Ghostling may only **suggest** manual repair,
pause, or cancellation when safe.

Every failed attempt is classified
`transient | deterministic | capacity | workspace | verification | unknown`
and linked by lineage with its route, failure fingerprint, checkpoint, retry
count, and sunk costs. Versioned per-class retry limits and cooldowns apply.
Repeated identical deterministic/unknown failures require explicit approval
plus fresh planning or verification; they are never automatically recycled
into the next unattended batch.

Only one live attempt per logical node/workspace is eligible unless the user
explicitly creates a comparison experiment. Orphaned sessions, outputs,
leases, and checkpoints must be reconciled by `RECONCILE_FAILURE` before a
replacement is admitted. Cross-provider recovery still requires an observed
portable checkpoint; otherwise the recommendation labels full restart cost.

### 8.11 Bounded plan search

Admission is a resource-constrained plan search, not a claim that greedy
candidate order is globally optimal.

Candidate construction is deterministic. Accepted work, active runs/retries,
attention requests, and due reviews always enter as fixed obligations or
conflicts, not optional top-K competitors. The `K=12` optional slots are filled
in stable, deduplicated order: six by priority vector, two oldest eligible, two
for project/flow representation, and two short-gap fits. Pinned work enters
first if feasible. Cards marked `defer_until`, `archived`, or
`never_auto_recommend` are excluded according to that explicit state.

Track exclusion age, deferral count, and last consideration. At the configured
maximum deferral, emit a triage suggestion—schedule, defer to a date, archive,
or never recommend—rather than silently inflating priority.

The explicitly oriented lexicographic `PlanScore` is:

1. minimize hard-violation count, then violation minutes (feasible = zero);
2. minimize unresolved accepted-conflict count;
3. minimize maximum, then total attention-SLA lateness minutes;
4. minimize interrupted protected-slice count;
5. minimize context-switch count, then fixed-point switch cost;
6. maximize fixed-point risk-adjusted reviewed-value units;
7. maximize useful unattended machine minutes;
8. minimize maximum normalized provider-constraint scarcity, then its sum;
9. minimize fixed-point uncertainty penalty.

Provider costs are normalized inside each non-fungible constraint before
comparison and never summed in raw units. Numeric components use signed
saturating 64-bit fixed point with a versioned scale; durations saturate at the
horizon, missing maximizing values are zero, and missing minimizing values are
the configured worst bound.

V1 considers at most the top `K=12` logical chains and `R=3` routes per chain
after hard gates. It uses deterministic branch-and-bound in stable node/route
order, capped by `10,000` expansions rather than wall time. The incumbent is
the best feasible `PlanScore`; output records
`search_complete | search_limited` and never claims optimality when limited.

Small scenario fixtures are exhaustively enumerated and compared with the
bounded search. Production diagnostics record the best score, search bound,
and pruned gates. Every partial branch has a component-wise optimistic vector
bound; prune it only when that lexicographic bound cannot beat the incumbent.
Diagnostics report vector bounds, never an undefined scalar optimality gap.

## 9. Recommendation contract

The primary card always contains:

- **Now:** one action with a card and bounded duration.
- **Why:** two or three decisive facts.
- **Until:** completion condition or expiry/recheck time.
- **Then:** at most two contingent next actions.
- **Confidence vector:** evidence, feasibility, ranking, search, phase, and
  accepted-risk dimensions with the downgrade cause.
- **Alternatives:** at most two feasible options and why they ranked lower.
- **Control:** `copy command`, `snooze`, `not now`, or `choose alternative`.

Global controls are `off | silent | passive | proactive`, `pause until`,
`done for today`, and immediate notification mute. Per-card controls are
`pin next`, `defer_until`, `archive`, and `never_auto_recommend`; per-route
controls exclude a provider/model or override **user-declared scheduling
availability**. They cannot change measured quota/capability state. All
overrides are scoped, visible, reversible, and excluded from preference
learning.

Override matrix:

- **Never override:** watcher-only behavior, separate pools,
  capability/data-policy floors, attestation identity, or measured exhaustion.
- **Explicit scoped override:** one recovery slice, one flexible calendar
  event, or unknown quota for resumable low-downside work.
- **Never convert to known:** missing quota/evidence or measured exhaustion.

Each override stores scope, expiry, accepted risk, and trace explanation.

Before batch acceptance, show a compact “now / before absence / later review /
risks” summary with the full conditional DAG and reservations available for
inspection. Safety-coupled nodes form an atomic `CommitmentBundle`: a launch
cannot be accepted without its machine resource/quota, integration-order, and
human review, accepted-integration, and post-integration-verification capacity
reservations. Users accept/reject per-task bundles, not
arbitrary mandatory nodes. Rejecting a prerequisite cascades to unstarted
descendants; accepting a child requires satisfied/accepted prerequisites.
Renewed confirmation is required only for material route, workspace, risk
class, or duration changes. “Why not task X?” uses the same decision trace.

Evaluation emits a structured `DecisionTrace` containing rejected gates and
evidence, candidate/plan vectors, the first differing dimension, route
constraints, reservations, conditional assumptions, decisive source
freshness, and search completeness. User-facing text is generated only from
this trace:

- state the binding reason first;
- cite only evidence actually used by the decision;
- describe alternatives counterfactually (“B would win if X changed”);
- expose conditional assumptions instead of phrasing them as guarantees.

Tests must assert that rendered explanations match the trace and never cite an
unused input.

Example:

> **Now — take a 12-minute break.** You completed two focus blocks and the next
> meeting starts in 24 minutes, leaving only 7 useful minutes after buffers.
> **Then — at 14:00 continue task-18 interactively.** The 70-minute free window
> fits its 55-minute p80. **Evidence: measured calendar / incomplete recovery.**
> **Feasibility: conservative. Ranking: baseline. Phase: A.**

No button is labeled Run, Start Agent, or Execute. Launch commands are
copy/reveal only.

## 10. Confidence and cold start

### 10.1 Confidence vector

Never collapse uncertainty into one label:

- `evidence_quality`:
  `validated_measured | measured | user_attested | estimated | unknown`;
- `feasibility_risk`:
  `calibrated_bounded | conservative_static | risk_accepted | unproven`;
- `ranking_confidence`:
  `calibrated | heuristic | baseline_only`;
- `search_completeness`: `complete | limited | disabled`;
- `capability_phase`: `A | B | C`;
- `risk_accepted`: false or the scoped override ID.

User-attested evidence never upgrades to measured. High launch feasibility
requires current validated gating evidence and calibrated joint bounds. Limited
search lowers ranking confidence without changing independently proven
feasibility.

Action-specific projection:

| Action class | Decisive evidence | Feasibility source | Ranking source |
|---|---|---|---|
| Launch bundle | attestations, quota, workspace, review window | joint/static upper bounds | active search or Phase-A table |
| Focus/planning slice | availability, boundary, duration | slice-fit bound | priority vector/baseline |
| Respond | reconciled attention request, response bound | SLA/window fit | attention vector |
| Rest/check-in | recovery evidence/assertion | configured lease | recovery rule |
| Review/integration | output revision, criterion ledger, window | obligation fit | debt/value vector |

The trace records the exact dimension and input that caused each downgrade.
Actions independent of missing resources may still be recommended, but their
unrelated dimensions remain explicitly unknown rather than lowering a generic
score.

### 10.2 Initial priors

Before enough outcomes exist:

- use broad, conservative duration classes supplied by the workflow;
- use provider/task compatibility declared by the user or Saha configuration;
- require explicit verification for autonomous readiness;
- display ranges and low confidence;
- do not infer “fast task” from title or token count.

### 10.3 Learning

Learn from every attempt: successful, failed, partial, interrupted, abandoned,
and right-censored long-running work. Store planned/actual or censored human
time, machine time, route cost, reliability, setup, review load, interruption,
and outcome. Update robust `p50/p80` estimative distributions by action type,
flow, provider, and task class only when the sample is large enough; otherwise
retain the broader parent prior.

Automatic learning is limited to estimative models. It never changes user
priorities, working hours, recovery policy, notification tolerance, or
guardrails from acceptance/rejection behavior. Every candidate model is
versioned with its prior retained, evaluated in shadow replay, and promoted
only when calibration/error improves with no guardrail regression. There is no
randomized exploration in the active advisor. Reinforcement learning remains
deferred.

## 11. Stability, overrides, and proactivity

- Do not change the primary recommendation inside its validity interval unless
  a hard constraint, attention urgency, or feasibility result changes.
- Record `accepted`, `snoozed`, `rejected`, `alternative_chosen`, and an optional
  reason. An override changes the immediate plan but not a hard product
  invariant such as suggest-only execution.
- Rejection suppression is scoped to the exact recommendation fingerprint and
  lease. It never changes priorities/settings or reduces hard/critical advice.

Recommendation computation is separate from a typed `DeliveryPolicy`:

- severity is `passive | boundary | interrupt`;
- default delivery is a passive board update;
- `boundary` waits for the next focus/Pomodoro boundary and bundles all pending
  changes once;
- `interrupt` is permitted only for user-enabled hard-boundary or
  critical-attention cases;
- deduplicate by recommendation fingerprint and coalesce concurrent source
  changes into one bundle;
- honor snooze until expiry unless severity increases to a strictly higher
  enabled class;
- enforce quiet hours, a configured maximum per interval, and at most one
  boundary bundle per focus boundary;
- unknown-recovery prompts are never `interrupt`.

## 12. Data governance

All state is local and encrypted at rest with a Keychain-protected key. There
is no telemetry or cloud synchronization by default.

Data is minimized by class:

- **Raw observations:** version/timestamp, opaque card/session IDs, numeric
  durations/capacity, and typed reason codes. Never persist terminal content,
  prompts, calendar titles/descriptions/attendees, or arbitrary failure text.
- **Active plan state:** only current nodes, reservations, evidence IDs, and
  conditional assumptions needed to replan.
- **Learning features:** numeric/categorical estimative features with card names
  and paths removed. Recovery and energy records are excluded.
- **Diagnostics:** decision traces with repository paths, card names, calendar
  metadata, recovery, and energy redacted by default.

Default retention is versioned configuration: raw observations 30 days,
decision traces 30 days, completed plan attempts 90 days, and aggregate
calibration features until reset. Raw attempts are aggregated or deleted after
model updates. The user can inspect, export, delete per card, delete by class,
or delete all local history; deletions also remove derived per-card features.

## 13. Failure modes and fallbacks

| Condition | Fallback |
|---|---|
| Calendar unavailable/stale | Avoid “meeting-free” claims; recommend only short/reversible work or ask for a free-until time |
| Pomodoro history incomplete | Show incomplete coverage; use explicit phase/check-in or conservative recovery policy |
| Recovery evidence unknown | Offer a break/check-in without claiming it is mandatory |
| Quota unknown/incomparable | Do not recommend heavy launch on that pool; allow continuing existing work |
| Duration unknown | Use broad class prior and require p80 fit |
| Plan/preflight attestation differs | Re-run only the invalid attestation; no launch |
| Meeting moved earlier | Expire the current recommendation and replan |
| Provider becomes exhausted | Remove new routes; preserve resumable work and suggest alternatives |
| Workspace/resource conflict | Isolate work or serialize the conflicting nodes |
| Unattended preflight/stabilization fails | Expire the run plan and recommend repair/cancellation before absence |
| Repeated identical failure | Stop automatic retry eligibility; reconcile and require explicit approval |
| Review queue over cap | Review before launching more autonomous work |
| Outside working hours | Stop or recovery; no “use spare quota” pressure |
| No feasible candidate | Explain the binding constraint instead of fabricating work |

## 14. Evaluation

### 14.1 Outcome metrics

- p50/p90 age of actionable waiting requests.
- Uninterrupted focus minutes and avoidable context switches.
- Planned vs. actual fit before calendar boundaries.
- Review-debt minutes and age.
- Reviewed high-value tasks completed per working week.
- Recommendation acceptance, snooze, override, and stale-advice rates.
- Break/stop recommendations accepted and work suggested outside preferences
  (target: zero for the latter).
- Provider-capacity use as a secondary metric only.
- Negative outcomes: missed hard commitments, quota lockouts, failed
  unattended windows, review-cap breaches, notification burden, repeated
  failures, and recovery-policy violations.

### 14.2 Guardrail checks

- Zero automatic process launches, prompt responses, calendar writes, or timer
  controls.
- A side-effect firewall test proves no scheduler/advisor path can execute a
  subprocess; create worktrees/branches/locks; signal a process; or write
  outside the app-owned plan/feedback store. Clipboard writes require the
  direct copy action.
- Zero recommendations that overlap a known hard calendar boundary.
- Zero autonomous launch recommendations without verified readiness.
- Zero route decisions that sum provider pools.
- Zero high-confidence claims whose decisive input is unknown or stale.
- Zero new-launch recommendations above review-debt or recovery caps.

### 14.3 Validation and rollout gates

Run the deterministic policy over a timestamped event log before enabling
proactive notifications. Replay should show the chosen action, rejected
candidates, binding gates, confidence, and explanation for every decision.

Required evidence:

- duration/cost upper-envelope calibration by provider/task class, including
  individual coverage and joint batch-overrun rate against `alpha`;
- bounded search versus exhaustive plans on small fixtures, recording
  lexicographic regret whenever search is limited;
- model/property tests for reservation conservation, legal DAG transitions,
  compare-and-swap races, crash recovery, and no double booking;
- adversarial replay for stale/out-of-order events, DST/time-zone changes,
  moved meetings, rolling resets, correlated overruns, failed attestations,
  orphaned sessions, and repeated failures;
- explicit cases for both DST transitions, travel-zone changes,
  midnight-spanning work, all-day/overlapping events, provider resets in a
  different zone, and costs crossing the detailed/coarse horizon boundary;
- silent-mode comparison against a documented baseline policy:
  “protect current focus until boundary; then choose the highest user-priority
  feasible card; never plan an unattended batch.”

Promotion gates are fixed before each pilot:

1. **Silent:** zero invariant/side-effect/property violations; exhaustive small
   fixtures match the exact optimum; no heavy unattended recommendation in an
   uncalibrated stratum.
2. **Passive:** the upper confidence bound on joint batch overrun is within the
   configured `alpha` tolerance; no worse than baseline on missed commitments,
   quota lockouts, review-cap breaches, or recovery violations; and the
   user-selected primary outcome improves or meets its declared
   non-inferiority margin.
3. **Proactive:** passive gates remain green, notification burden stays under
   the configured cap, stale-advice rate is below its declared threshold, and
   the user explicitly enables boundary/interrupt delivery.

Acceptance rate alone is never a promotion criterion.

## 15. Open user-review decisions

The algorithm is complete without fixing these personal policy values:

1. Default focus/break cadence and when recovery becomes mandatory.
2. Working/quiet hours and meeting buffers.
3. Review-debt cap and autonomous concurrency cap.
4. Whether unknown quota may appear as an explicit-confirmation launch option.
5. Which calendar events are flexible and whether calendar availability may be
   read beyond free/busy.
6. Notification channels and cooldown.
7. The user-defined value/priority scale used to compare cards.

These are settings, not hidden model weights.

## 16. Normative implementation contract

Decision-affecting terms, schemas, defaults, pure functions, and exact golden
outputs are defined in:

- [Normative contracts](research/normative-contracts.md)
- [Contract JSON Schema](research/contracts-v1.schema.json)
- [Canonical policy profile](research/policy-profile-v1.yaml)
- [Phase-A route manifests](research/phase-a-route-manifests-v1.yaml)
- [Golden scenarios](research/golden-scenarios-v1.yaml)

Schemas and reference vectors override conflicting prose; prose examples are
non-normative.

## 17. Capability-phased delivery

The target policy above is capability-gated. Each adapter/model reports
`disabled | degraded | enabled_unvalidated | validated`; the UI may claim only
what that state supports.

### Phase A — first shippable policy

- `silent` or `passive` delivery only; no interrupts.
- Existing reconciled board attention state, always confidence-labeled.
- Manual `available until` / absence input; no inferred calendar-free claim.
- Current Saha plan attestation plus a low-confidence
  `ManualLaunchPreflightAttestation`:
  `{static_manifest_version, route, workspace, base_commit, credentials_check,`
  `execution_config_hash, manual_assertion_id, expires_at}`.
- Built-in versioned compatibility manifests only for explicitly supported
  Phase-A routes. Manual preflight expires after 15 minutes or immediately on a
  route/workspace/base/credential/config/source-generation change and is
  reconfirmed before launch.
- A scoped `ManualReviewWindowAssertion` whose conservative capacity covers the
  sum of review, accepted-integration, and post-integration-verification upper
  bounds. Without it, Phase A recommends planning/preflight only.
- Static conservative human/runtime/review classes.
- At most one resumable, low-downside autonomous run at a time, using measured
  and comparable quota. Unknown/incomparable or measured-exhausted pools cannot
  receive a launch recommendation.
- No automatic learning, cross-provider continuation, multi-run unattended
  batch, or hard recovery decision from incomplete Pomodoro data.
- Simple deterministic baseline selection plus decision trace; bounded search
  may run in shadow only.

`LaunchPreflightEvidence` is a sum type:
`ManualLaunchPreflightAttestation | ValidatedLaunchPreflightAttestation`.
Phase-A `low-downside` means the static manifest declares resumable execution,
no cross-provider checkpoint requirement, acceptable-output floor at or above
the profile threshold, repair/review upper bounds within the asserted review
window and debt cap, and sunk-quota upper bound within the profile limit.

Phase-A decision table, first matching row:

1. outside working hours or done-for-day → `SHUT_DOWN`; otherwise
   evidence-supported `known_due` recovery → `REST`;
2. fresh high-confidence attention SLA at risk → `RESPOND`, ordered by maximum
   lateness, then request ID;
3. protected current slice remains feasible → continue to its boundary;
4. outstanding completion debt fits now → choose `REVIEW`, then
   `SUGGEST_INTEGRATION`, then `POST_INTEGRATION_VERIFY`; within type order by
   hard deadline, descending criterion value, then card ID;
5. one plan-attested, manually preflighted low-downside launch bundle has
   measured/comparable quota and an asserted review window → suggest launch;
6. upcoming manually asserted absence lacks ready work → `PLAN_SAHA`, ordered
   by descending user priority then card ID;
7. short gap → first: fresh response that fits; second: due recovery check-in;
   third: `SMALL_ADMIN`; otherwise `REST`;
8. otherwise → feasible focus card by descending user priority, earliest soft
   deadline, action precedence, then card ID; `REST` if none.

If multiple Phase-A routes pass, choose the smallest worst normalized scarcity;
tie by stable route ID. Review debt uses static upper bounds and blocks row 5
when the configured cap or asserted review window would be exceeded.

### Phase B — validated adapters

Enable read-only calendar/free-busy, operator availability, timer recovery
evidence, route manifests, dual attestations, encrypted attempt history, and
passive conditional batch planning only after their individual tests pass.

### Phase C — calibrated optimizer

Enable multi-run batches, learned joint envelopes, bounded search as the active
selector, cross-provider portable-checkpoint recovery, then proactive
boundary/interrupt delivery in that order, each behind §14 rollout gates.

Missing-capability degradation is explicit:

- no calendar/operator availability → manual free-until actions only;
- no timer/break evidence → passive recovery check-in, never hard rest;
- no route manifest/attestation → planning or preflight only, never launch;
- no calibrated cost/duration → static upper class and one-heavy-run limit;
- no portable checkpoint → same-route resume or labeled full restart;
- disabled optimizer → documented baseline, not an “optimal” claim.

## 18. Success criteria

- [x] Ten documented proposal/critique iterations are complete.
- [x] The policy covers multi-provider routing, Saha and interactive flows,
      Pomodoro recovery, calendar-aware focus, and proactive unattended work.
- [x] Suggest-only, single-threaded human attention, separate-pool accounting,
      readiness, recovery, and review-debt invariants are explicit.
- [x] Every recommendation is deterministic, explainable, confidence-labeled,
      and stable enough to act on.
- [x] Cold-start, missing-data, override, and failure behavior are defined.
- [x] Metrics and replay evidence can evaluate effectiveness and guardrails.
- [x] The artifact is ready for user review before implementation planning.
