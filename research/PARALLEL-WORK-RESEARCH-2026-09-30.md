# How power users run more agent work in parallel — research, 2026-09-30

Four web-research passes (practitioner accounts, orchestrator tools, autonomy
mechanisms, async/cloud surfaces), filtered against this operator's own data
(`research/stop-replies/FINDINGS.md`: avg parallelism 1.2, 48% of stops
avoidable, 27% of replies are questions to the agent) and current setup (auto
permission mode, ntfy Stop hook, 12/223 cards on worktrees, second Claude
account pending, no use of /goal, /loop, /batch, /schedule, cloud sessions or
`claude agents`).

## 1. What the sustained 5–10-agent people have in common

| Practice | Who | Source |
|---|---|---|
| One worktree/checkout per session; plan mode first, then one-shot the implementation; done = notification | Boris Cherny (5 local + 5–10 cloud, 20–30 PRs/day) | howborisusesclaudecode.com; Pragmatic Engineer 2026-03-04 |
| Issue → PR is the unit; `/issues`, `/work`, `/review` slash commands route it; human reviews only business logic/UX | Kieran Klaassen | every.to 2026-01-26 |
| Review findings, not diffs: N reviewer agents → `/triage` ranks by severity, <2 min per finding | Klaassen | every.to 2026-01-23 |
| Loop engineering: a cron agent dispatches work to threads; one agent writes, another checks | Steinberger; Ronacher "The Coming Loop" 2026-06-23 | yahoo/tech; lucumr.pocoo.org |
| Ralph loop with backpressure (tests/hooks) as the done-signal; ~80% completion on well-defined tasks | Huntley | ghuntley.com/loop 2026-01-17; developersdigest 2025-12-29 |
| Proof-based review: accept big diffs only with screenshots/demo video | Thorsten Ball / Amp | ampcode.com/notes 2026-08-04 |
| Parallelize only low-review work (research, maintenance, tightly specified changes); one significant change at a time | Simon Willison | simonwillison.net 2025-10-05 |
| Competition not pipeline: same prompt to N copies/models, keep the best; ignore notifications | Mitchell Hashimoto | zed.dev 2025-06-19 |
| Every mistake → CLAUDE.md/AGENTS.md line, never fixed in chat | Cherny, Hashimoto | as above |
| One heavy + 2–3 light sessions; rename every session | Alex Dunlop | substack 2026-06-22 |

What breaks first, in their words: human attention (Willison "wiped out by
11am"; Osmani ceiling 3–4; Dunlop "attention degrades under load"), merge
conflicts, orphaned processes, upstream starvation ("a LOT of planning to keep
the engine fed", Appleton on Gas Town). Contrarians (Ronacher "Agent Psychosis",
Hashimoto, many HN) say >2–3 heavy threads is theatre for code you care about.

Synthesis: nobody sustains N *heavy* threads. They sustain 1 heavy interactive
thread + N *light* threads, where light = fully specified, low-review,
done-checkable work. Our data agrees: 27% of replies are questions (the heavy
thread), and the avoidable stops cluster in the light class.

## 2. Native Claude Code features that replace things we planned to build

- `/goal <condition>` — session-scoped prompt-based Stop hook; Haiku judges
  Met / Not yet / Impossible after every turn; ends after several no-tool turns;
  check-ins at 30 min / 1 h / 2 h. Best-practices ranking: prompt → /goal →
  deterministic Stop hook → verification subagent. (code.claude.com/docs/en/goal)
- Stop hook contract: `{"decision":"block","reason":"…"}`; `stop_hook_active`
  guards loops; eight consecutive no-progress blocks are overridden. Anthropic
  ships a `ralph-wiggum` plugin with `--max-iterations` and a completion promise.
- Auto permission mode "nudges Claude to keep working without stopping for
  clarifying questions"; pauses after 3 consecutive / 20 total classifier blocks.
- `/loop <interval> <cmd>` in-session cron (PR babysitting), `/batch` fan-out of
  5–30 worktree subagents, `claude agents` local supervisor grouping sessions by
  Needs input / Working / Ready for review (research preview, v2.1.281).
- Cloud sessions (`claude --cloud`, `--teleport` back), Projects (one
  conversation spawning parallel cloud threads with an Overview: Ready for
  review / Waiting on you / Landing), Routines (cron ≥1 h, `/fire` endpoint,
  GitHub triggers). All bill against the subscription, no separate compute
  charge; parallel sessions burn proportionally. One-time cloud credit
  ($250 on Max) via `/claim-credit` until 2026-10-07.
- Slack: `@Claude` in a channel → cloud session under your plan; Remote Control
  drives a local session from the phone; Dispatch spawns sessions from chat.

Consequence for the "watcher, not spawner" rule: its economic basis was that
`claude -p` bills the separate API/credit pool. Cloud sessions and Routines
bill the interactive subscription. The rule narrows to "never spawn headless
`claude -p` on API credit"; subscription-billed cloud threads are a legitimate
second lane, observed by the board as remote cards if their hooks can reach us
(open question).

## 3. Multi-account and spillover

Anthropic (T. Shihipar): multiple Max accounts are not against ToS; the banned
pattern is token pooling/relays. Allowed pattern = separate `CLAUDE_CONFIG_DIR`
profiles each logged in — exactly what Sich's account picker does. Weekly caps
tightened 2026-09-14 (permanent +25% vs the summer +50%). Heavy users route
Claude for complex work and Codex as spillover when a window is exhausted.
`claude-tracker` (github.com/DSado88/claude-tracker) shows N accounts' 5-h and
7-day windows side by side.

## 4. Orchestrator tools worth knowing (all verified 2026-09-30)

Host-interactive (same model as Sich): cmux (Swift/libghostty, OSC-based
attention, `claude-teams` subagent panes), Superset (worktree per workspace,
automations, mobile), Emdash (25+ CLIs, SSH, imports Linear/GitHub issues),
Claude Squad (tmux+worktree TUI), Paneflow, Calyx (single approval inbox for
every permission prompt across panes). Spawners: Vibe Kanban (company shut
2026-04, OSS local app), Sculptor (Imbue, "CI babysitter"), Symphony (OpenAI,
Linear issue → workspace, `max_concurrent_agents`, proof-of-work PRs), Codex
cloud (`--attempts 1–4` best-of-N), Cursor cloud agents (`/best-of-n`), Devin,
Jules, Factory, Warp/Oz, Kiro, Copilot cloud agent (59-min sessions). Dead:
Terragon, Crystal (→ Nimbalyst).

Borrowable for Sich: approval inbox answerable without drilling in; done-unviewed
and blocked as distinct card states; per-card PR lifecycle (Ready for review /
Landing, auto-archive on merge); quota-aware new-card gating ("N agents ≈ N×
quota"); best-of-N sibling cards from one brief; subagents as child rows;
diff pane with line comments that become the next prompt.

## 5. Recommendations for this operator (ordered by expected gain per effort)

1. Kill the PR-review ritual: a `/review-pr <n>` skill that checks out, reads
   comments, TLDRs, reviews, posts plain comments in your name (no approve, no
   Claude mention), and a global rule + pre-allowed `gh pr comment`. ~15% of
   all stops.
2. Put the eight standing rules from FINDINGS.md into global CLAUDE.md; put
   every future correction there too (Cherny's rule), never only in chat.
3. Start every implementation card with `/goal <done-when>` and a brief of the
   form goal / done-when / then / defaults. Replaces the planned Sich Stop-hook
   gate; the 23 false-done stops and the 16 early-Esc corrections are its
   target.
4. Move the light class off your Mac: PR reviews, research questions,
   maintenance, "check the review status" → cloud sessions or a daily Routine.
   Claim the cloud credit before Oct 7. Keep the heavy thread local in Sich.
5. Sign in the second Claude profile and let the palette preselect the account
   with headroom; use Codex as spillover when a window is exhausted.
6. Best-of-N for ideas: three worktree cards from one brief, `/goal`-gated,
   keep the best. Cheap with spare capacity; evaluation replaces planning.
7. Model the day as 1 heavy + N light, not N heavy. Re-derive the "cap at 2–3"
   operating rule after the light lane exists; the data behind it was
   measured when every thread was heavy.
