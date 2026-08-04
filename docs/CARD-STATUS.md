# Card Status Rules (target behavior)

**Status: SPEC — this is what we want to achieve.** Current detection is unstable;
this document is the contract card movement should converge to. When observed
behavior and this doc disagree, the behavior is the bug.

The board renders four column groups (`BoardView.ColumnGroup`), left to right:

| Column | Meaning | Underlying `CardState`s |
|---|---|---|
| **QUEUE** | not started / at rest | `idle`, `unknown` |
| **WORKING** | an agent is actively producing | `running`, `running-tests` |
| **NEEDS YOU** | the operator must act | `waiting-for-input`, `blocked` |
| **DONE** | operator declared it finished | `done` |

Every `CardState` maps to exactly one column — a card can never silently vanish
from the board.

---

## Interactive flow (human-launched terminal: Claude Code / Codex)

1. **Not started → QUEUE.** The user created the card but has not launched or
   engaged an agent session in it. The card sits in QUEUE.

2. **Agent turn in progress → WORKING.** The user started working and the agent
   is doing something: generating, running tools, or **waiting on its own
   subagents**. Waiting-for-subagent is WORKING, not NEEDS YOU — the loop is
   still autonomous and no operator action is useful yet.

   2.1. **Stall guard → NEEDS YOU after 10 minutes.** If a card has been in
   WORKING for **10 minutes with no new output/content produced**, it moves to
   NEEDS YOU. Rationale: a genuinely progressing agent emits *something*; a
   silent 10-minute stretch means it is hung, stuck on a hidden prompt, or dead
   — all cases where the operator should look. Any new observed output while in
   this stalled state returns the card to WORKING and resets the timer.

   2.2. **Compaction is WORKING.** While the agent rewrites its own context
   (`PreCompact` through the `SessionStart` it re-emits on completion) the card
   shows WORKING — compaction is autonomous work, not an operator wait. When
   compaction completes the card returns to whatever it interrupted: a mid-turn
   auto-compact resumes WORKING; a manual `/compact` typed after an ended turn
   goes back to NEEDS YOU, since the agent is again waiting on the operator.

3. **Turn ended, agent waiting for the user → NEEDS YOU.** The agent stopped
   (finished its turn, asked a question, requested permission) and is idle until
   the user types. This is the attention signal the whole board exists for.

4. **DONE is manual and sticky.** Only the operator moves a card into DONE
   (drag / explicit action). Once in DONE, **no automatic rule moves it** —
   detector signals, hook events, and stall timers are all ignored for a DONE
   card. Completion is an operator decision, never a detector guess.

   4.1. **Leaving DONE re-arms automation.** If the user drags a card back out
   of DONE, the card is ordinary again: rules 1–3 (and 2.1) apply from that
   moment based on what is actually observed in its session.

---

## Saha flow

Which rules apply depends on the *phase* the card is in, not on the flow tag
alone.

1. **Planning phase (interactive planning mode).** Planning is a human-driven
   conversation in a terminal that produces the planning docs (`model/*.c4`,
   `progress.yaml`, …). Status tracks **that terminal exactly like the
   interactive flow**: agent producing → WORKING; agent stopped awaiting the
   planner's answer → NEEDS YOU; 10-minute silent stall → NEEDS YOU; manual
   DONE sticky. There is no special "planning" status.

2. **Agentic phase (`saha run …` in the CLI).** The card mirrors the agentic
   loop, which has only two live states:
   - **Loop running → WORKING.** The execution loop is iterating
     (implementer / QA / manager / DoD agents cycling). Individual agent
     handoffs and waits inside the loop are still WORKING.
   - **Loop stopped → NEEDS YOU.** The loop exited for *any* reason — DoD
     reached, iteration cap, failure, interrupt. A stopped loop always needs a
     human verdict (sign off, resume, or fix), so it never parks in QUEUE and
     is never auto-guessed into DONE (rule: DONE stays manual, same as the
     interactive flow).

---

## Cross-cutting invariants

- **Manual launches are first-class.** All of the above must hold even when the
  user starts `claude` / `codex` **themselves in a terminal** — inside a card's
  terminal or any other terminal — rather than the app auto-starting the agent
  at task creation. This is the *common* case after an app restart: the card
  exists, its PTY is a plain shell, and the user types `claude` by hand. Status
  detection must not depend on app-injected launch state; a session observed
  only through global hooks must drive the same QUEUE/WORKING/NEEDS YOU
  transitions as an app-launched one.

- **DONE only by hand.** No code path other than a manual operator move may set
  `done`. (Already enforced: `CardState.detectorFallback` keeps `done` sticky.)
- **Never guess.** A state that cannot be positively determined renders as
  `unknown` (QUEUE), not as an invented WORKING or NEEDS YOU.
- **Fresh beats stale.** When multiple observations compete for one card, the
  most recently observed state wins (`BoardCard.updatedAt` ranking).
- **NEEDS YOU is the product.** False WORKING (agent actually waiting) hides
  work from the operator and is the worst failure mode; the stall guard (2.1)
  exists to bound how long that can last.
