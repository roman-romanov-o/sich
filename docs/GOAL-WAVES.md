# Goal waves: running 5–6 `/goal` sessions at a time

Sourced from Anthropic's `/goal` and best-practices docs, OpenAI's Codex goals
cookbook, Symphony, compound-engineering, Matt Pocock's ticket sizing, and the
2026 practitioner reports on `/goal` failures (details and URLs in
`research/GOAL-RESEARCH-2026-09-30.md`). Nothing first-party generates the
condition for you; `/g <intent>` in any session does it with this grammar.

## How `/goal` behaves (facts that shape everything below)

- `/goal <condition>` starts the turn itself with the condition as the
  directive. The line is the whole brief. One goal per session; a new one
  replaces it; `/goal clear` stops it; goals survive `--resume`.
- After every turn a small model (Haiku) judges Met / Not yet / Impossible
  **from the transcript only**. It runs nothing. If the proof never appears in
  the conversation, the goal can never be met.
- The turn cap is text the evaluator reads, not a hard limit. Hard caps exist
  only in `/ralph-loop --max-iterations` and Symphony's `max_turns`.
- Auth failure, exhausted credits, unrecoverable context overflow or a missing
  model **clear** the goal. Rate limits pause it and it resumes when the
  window resets. Background jobs defer evaluation with 30-min check-ins.
- No tool use for several turns in a row stops the loop with the goal set.

## The goal grammar: six slots, one small brief

Codex's cookbook and Anthropic's docs converge on the same shape. Short goals
that state only an outcome get judged "met" on self-assessment (DevelopersIO
2026-09-15: "improve the quality of lib/pricing.rb" was met after one turn).
A strong goal "reads like a small task brief, not a wish".

```
END    <one measurable end state, packaging included>
PROOF  <the command the agent must run AND display: exit code, diff stat, file>
FENCE  <what must not change, closed against escapes>
CAP    or stop after <N> turns
STOP   if blocked: report attempted paths, evidence, the blocker, the input needed
LOG    (exploratory goals only) each turn record what changed, what the check showed, next experiment
```

Numbered clauses on several lines are fine (limit 4,000 chars). Rules per slot:

| Slot | Rule | Why (source) |
|---|---|---|
| END | one end state; include commit/PR/comment/file so wrap-up never becomes a question | Anthropic docs; our stop dataset (11–15% of stops were wrap-up asks) |
| PROOF | name the command and say "paste the exit code" / "display `git diff --stat`" / "show `gh pr view N --comments`" | evaluator reads only the transcript (docs); "show evidence rather than asserting success" |
| FENCE | enumerate escapes: "no test deleted, skipped or weakened", "no files outside `<dir>`", "no new files", "no public API change", "`git status` clean at the end" | fences were gamed by adding a new file, skipping tests, editing assertions (DevelopersIO, reporails) |
| CAP | 8 chores · 10 reviews/research · 20–25 features · 40 sweeps, plus "and report what's left" | Anthropic example "or stop after 20 turns"; Symphony default 20 |
| STOP | a blocked exit distinct from done, so the run ends with usable evidence, not a fake pass | Codex cookbook; ralph `<promise>BLOCKED:…</promise>` |
| LOG | benchmarks and tuning only | Codex cookbook "iteration policy" |

Sizing: one goal = one fresh context window ("smart zone" ~100k tokens),
demoable when done, a tracer bullet through all layers (Pocock); Devin's
guidance is ≤3 hours of human work. Bigger: split into sequenced goals.

## Six templates

1. **Fix / feature**
   `<tests> pass including a new test for <X>; <build> is clean; committed on
   <branch>, PR open against <base> with CI green. Proof: paste the exit codes
   of <test cmd> and <build cmd>, and \`git diff --stat <base>\`. Fence: only
   files under <dir> and their tests change; no test deleted, skipped or
   weakened; no new dependencies. Or stop after 25 turns and report what is
   left. If blocked, report attempted paths, evidence, the blocker and the
   input needed.`
2. **PR review**
   `A review of PR #<n> is posted as short plain PR comments in my name (no
   approve, no Claude/AI mention) covering correctness, security and scope.
   Proof: show \`gh pr view <n> --comments\`. Fence: no code changes on the
   branch. Stop after 10 turns.`
3. **Research / question**
   `<path>.md answers: (1) <Q1> (2) <Q2> (3) <Q3>, each with sources, under
   800 words. Proof: \`cat <path>.md\`. Fence: no code changes. Stop after 10
   turns; if a question cannot be answered from available sources, say so in
   the file.`
4. **Migration / sweep**
   `\`grep -rn <old> <dir>\` prints nothing; <tests> pass; one commit per
   file. Proof: paste the grep output and the test exit code. Fence: no
   behaviour change; no test edited. Or stop after 40 turns and list the
   files left.`
5. **Ops / verify**
   `<command> returns <expected> on <host>; a screenshot saved at <workspace
   path> shows <what>. Proof: paste the command output and \`ls -la <path>\`.
   Fence: nothing left in /tmp; no config outside <dir> changes. Stop after 12
   turns; if the host is unreachable, report the exact error.`
6. **Benchmark**
   `bench/RESULTS.md holds baseline and new-flow numbers on <corpus>
   measured by <command>; new ≥ <target> or the file says why not. Proof:
   \`cat bench/RESULTS.md\`. Fence: correctness suite stays green; only
   <service> changes. Each turn record what changed, what the benchmark showed
   and the next experiment. Stop after 20 turns.`

## When the transcript-judged gate is not enough

Anthropic's ranking: prompt → `/goal` → deterministic Stop hook → verification
subagent. Escalate when the agent can edit the thing that proves it
(tests, checklist, hook):

- Deterministic gate: a Stop-hook script that runs the tests itself and
  returns `{"decision":"block","reason":…}`; capped at 8 consecutive blocks.
- Hard turn cap: `/ralph-loop "<prompt>" --max-iterations N`.
- Second opinion at harvest: `/code-review` or a subagent asked for gaps
  against the goal, told to report only correctness gaps (reviewers prompted
  to find gaps always find some).

## The wave rhythm

A wave is 5–6 light goals dispatched together into one 5-hour quota window.
Light = fully specified, low-review, proof-in-transcript (reviews, research,
sweeps, ops checks, tightly scoped changes). Heavy work (design choices,
unfamiliar code, anything you'd want to steer) is your own single thread and
never goes in a wave. Two waves a day matches OPERATING-RULES.md Rule 3.

1. **Plan (15 min).** Write goal lines into a queue file (`.sich/goals.md`
   per repo or `~/.sich/goals.md`). `/g` drafts them; you edit. Pocock's
   dispatch rule: count the goals with no open blocker, open that many
   sessions, one goal per fresh context. Anything needing a credential, host
   or account gets it in the line now, or the run ends "impossible".
2. **Dispatch (5 min).** One card per goal; worktree per card in a shared
   repo; the `/goal` line is the first prompt. Goals with no local state can
   go to Claude Projects instead: paste the list, one cloud thread per item,
   subscription-billed, threads park at the limit and auto-resume.
3. **One glance at +5 min.** Your own data: 16 of 37 Esc interruptions were
   course corrections in the first 30 seconds. A single sweep five minutes
   after dispatch catches wrong-direction starts for the price of one glance.
   Then ignore WORKING cards. NEEDS YOU during a wave means Impossible,
   Blocked or a permission block, not a progress report.
4. **Harvest (30–45 min).** Per card, in this order: proof output → review
   findings → diff only where a finding points. Klaassen's triage rules:
   findings as issue cards with severity P1/P2/P3 and file:line, answer
   yes/next/custom per item, no coding during triage. Then merge, redo with a
   sharper line, or kill. Every correction you type becomes a CLAUDE.md line
   or a template fix, never only a chat message.
5. **Next wave** is already in the queue; blocked goals go back with the
   missing input supplied.

## Capacity rules (from people who ran overnight batches)

- Don't dispatch when more than 20% of the 5-hour window is used; stop
  dispatching at 60%; skip the wave if the weekly cap is above 80%.
- N parallel goals burn about N× one session. Check the pool gauge first.
- One dev server per worktree collides on ports: put the port in the FENCE
  or run one server-bound goal per wave.
- Review is the real ceiling. Six light goals harvest in under an hour when
  proof is in the transcript; the industry number for a human sign-off on one
  real change is ~40 minutes, so two heavy ones would not fit.
