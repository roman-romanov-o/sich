# Card Status Rules (target behavior)

**Status: SPEC — this is what we want to achieve.** Current detection is unstable;
this document is the contract card movement should converge to. When observed
behavior and this doc disagree, the behavior is the bug.

The board renders six column groups (`BoardView.ColumnGroup`), left to right:

| Column | Meaning | Underlying `CardState`s |
|---|---|---|
| **QUEUE** | ready to pull / at rest | `idle` |
| **PARKED** | shelved on purpose (defer, unknown host) | `parked`, `unknown`, `unreachable` |
| **WORKING** | an agent is actively producing | `running`, `running-tests` |
| **NEEDS YOU** | the agent waits on **you** | `waiting-for-input` |
| **BLOCKED** | waiting on **external** factors (PR review, upstream) | `blocked` |
| **DONE** | operator declared it finished | `done` |

Every `CardState` maps to exactly one column — a card can never silently vanish
from the board.

---

## Interactive flow (human-launched terminal: Claude Code / Codex / Cursor)

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

   2.3. **A backgrounded subagent keeps the card WORKING.** Claude fires a
   `Stop` when the main turn parks with "Waiting for N background agents to
   finish" — but that Stop's own payload lists the still-running child in
   `background_tasks`. Such a Stop (and the ~60s `idle_prompt` nudge that
   follows it) parked the *prompt*, not the *work*: the card stays WORKING and
   the turn latch does not arm. The FINAL Stop — the one whose payload reports
   the background drained — is the real turn end and routes NEEDS YOU as usual.
   The stall guard (2.1) still bounds the parenthesis: a child that goes silent
   past the threshold routes attention anyway.

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

---

## Cross-cutting invariants

- **Manual launches are first-class.** All of the above must hold even when the
  user starts `claude` / `codex` / `agent` **themselves in a terminal** — inside a card's
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

## Cursor specifics

- Cursor's CLI (`agent` / `cursor-agent`) has no per-invocation hooks flag, so the
  board wires its hook script into the user-level `~/.cursor/hooks.json` once
  (merged, never overwritten). The script emits nothing unless `SICH_CARD_ID`
  is in its environment, so Cursor sessions outside a Sich terminal stay silent.
- Cursor has no permission-request hook and no on-screen menu the board
  scrapes, so a Cursor approval prompt does **not** light NEEDS YOU; the card
  shows WORKING until the turn ends (`stop`).
- Resume is `agent resume` (latest chat, not cwd-filtered): with several Cursor
  cards open, a revived card may pick up the most recent chat rather than its own.
- Cursor quota is MEASURED the same way Claude's is: a hidden pty runs `agent --trust` in `~/.sich/usage-probe`, types `/usage`, and parses the `Included NN% used` row + `Resets Mon D` (one monthly pool, no tokens or keychain touched). Refreshed every 5 min; `swift run sich-probe cursor` runs one scrape by hand.

## Antigravity specifics

- Google's Antigravity CLI (`agy`) is wired like Cursor: one hook script
  (`~/.sich/hooks/sich-antigravity.sh`) merged as the named `"sich"` entry of the
  user-level `~/.gemini/config/hooks.json`; the script emits nothing unless
  `SICH_CARD_ID` is in its environment. The `~/.sich/bin/agy` shim pins the
  launch cwd/pid and execs the real binary (`~/.local/bin/agy` or PATH).
- Antigravity hook payloads carry **no event name**, so each installed command
  passes it (`sich-antigravity.sh Stop`) and the script stamps `hook_event_name`.
  `PreToolUse` is **not** hooked — Antigravity requires a permission `decision`
  from it, which a watcher must never answer. `PreInvocation`/`PostInvocation`
  (model call edges) and `PostToolUse` mean WORKING; `Stop` means the turn ended.
- No permission-request hook → an Antigravity approval prompt does **not** light
  NEEDS YOU; the card shows WORKING until `Stop`.
- Resume is `agy --continue` (the most recent conversation in the workspace).
- Antigravity quota is MEASURED via the same hidden-pty scrape: `agy` in
  `~/.sich/usage-probe`, the "trust this folder" dialog accepted, `/usage` typed
  once "? for shortcuts" shows, and the "Models & Quota" page parsed per model
  bucket (`NN% used`, `resets in …`, `Disabled` rows skipped). The gauge shows the
  TIGHTEST bucket. The page layout has only been seen described, not captured —
  `swift run sich-probe antigravity` (after `agy` sign-in) validates it; drift
  degrades to `unknown`, never a fake number.
