# Operating rules (pace & attention)

Evidence-backed habits from Sich worklog analytics (Aug–Sep 2026). The app
enforces **Rule 1**; the rest are operator practices until we wire them in.

See also: `scripts/worklog_analytics.py` for offline stats on your machine.

## Rule 1 — NEEDS YOU standup (enforced in app)

**Habit:** Once or twice per day (~15 minutes), touch every card in NEEDS YOU:

- **Respond now** — drill in, decide, send the next instruction.
- **Park until tomorrow** — move to **PARKED** until tomorrow (explicit snooze; not silent abandonment).
- **Blocked externally** — move to **BLOCKED** when you are waiting on others (PR review, upstream), not the agent.
- **Done / archive** — finish or kill work that will not ship.

**Goal:** No ask sits unattended past the staleness threshold (default **8 hours**
waiting) unless you explicitly deferred it.

**App behavior:** Stale NEEDS YOU cards (waiting **≥ 8 hours**, not explicitly
deferred) trigger a standup prompt on launch and when the app becomes active.
Choose **Respond now**, **Park until tomorrow**, or **Mark done** — or dismiss
with Cancel / Escape. Context menu: **Park until tomorrow…**, **Blocked
externally…**, **Park for later…**. Park-until-tomorrow deferrals persist in the
task book until the next local midnight.

## Rule 2 — Cap open asks (WIP for your brain)

Keep at most **2–3** cards in NEEDS YOU. Everything else: defer to queue with a
one-line note or archive.

*Why:* Parallelism above ~2 matches “glance mode” in the logs; many open asks
create decision debt while you are distracted.

## Rule 3 — Batch drill-ins

Prefer **two focused windows** (e.g. late morning + late afternoon) to process
NEEDS YOU and one deep task. Avoid all-day scatter (high entry days correlated
with >50% “glance” visits ≤10s).

## Rule 4 — Two-minute rule at the prompt

If you are in the terminal on a NEEDS YOU card for **>10 minutes** without
typing a decision, default to: yes / no / one-sentence defer — then leave.

## Rule 5 — Longer autonomous chunks (agent handoff)

Ask for a clear “next chunk until X or blocked” in handoffs so post-feedback runs
are not only ~3 minute micro-loops.

## Rule 6 — Finish before spawning

Bias toward **done or kill** before starting another interesting task. Weekly
“→ done” throughput beats a fourth parallel agent for your attention model.

## Analytics anchors (your machine, Sep 2026)

| Signal | Rough value |
|--------|-------------|
| Sweet spot for parallel agents | **~2** running |
| Median response when engaged | **~4 min** |
| Long-tail pain | NEEDS YOU waits **>8 h** and **>24 h** |
| Typical post-feedback agent run | **~3 min** median |
