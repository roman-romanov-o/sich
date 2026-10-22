# Sources behind docs/GOAL-WAVES.md (fetched 2026-09-30)

## /goal semantics and examples
- code.claude.com/docs/en/goal — evaluator reads transcript only; one goal per session; turn clause "or stop after 20 turns"; clears on auth/credits/context overflow/model; pauses on rate limit; 30-min check-ins; shipped v2.1.139 (2026-05-11).
- code.claude.com/docs/en/best-practices — "Claude stops when the work looks done"; "show evidence rather than asserting success"; gate ranking prompt → /goal → Stop hook → verification subagent; interview → SPEC.md; adversarial reviewer caveat.
- developers.openai.com/cookbook/examples/codex/using_goals_in_codex — six-slot pattern: outcome, verification surface, constraints, boundaries, iteration policy, blocked-stop clause. Example: "Reduce p95 checkout latency below 120 ms, verified by the checkout benchmark, while keeping the correctness suite green… If the benchmark cannot run or no valid paths remain, stop with the attempted paths, the evidence gathered, the blocker, and the next input needed."
- cursor.com/changelog 2026-08-19 — Cursor /goal, no writing guidance.
- xda-developers 2026-09-10 — numbered checklist form: "Stop only after: 1. npm test -- test/auth exits 0. 2. npm run lint exits 0. 3. No tests deleted, skipped, or weakened. 4. git diff shows no unrelated changes. 5. The final response reports the commands run and results."
- buildgreatproducts.com/guides/claude-code-goal 2026-05-14 — "a strong goal reads like a small task brief, not a wish"; End state / Check / Constraints / Bound example.

## Failure modes
- dev.classmethod.jp 2026-09-15 (CC 2.1.271) — "improve the quality of lib/pricing.rb" judged met after 1 turn; "don't modify" fence gamed by adding a new file; tight fence + failing baseline → Impossible in 1 turn; Stop hook without stop_hook_active guard blocked 9×.
- reporails (dev.to) — assertions edited, @pytest.mark.skip, hardcoded returns; grader must be read-only / held-out.
- SpecStory 2026-09-29 — audit: 65–69% of "done" claims lacked test evidence; proof must run outside the agent's report.
- snarktank/ralph PR #93 2026-02-09 — replaced completion string with a jq query over a PRD's `passes` flags.
- HN 46682325 — "If the AI thinks things work, it will say COMPLETE."
- futureagi 2026-08-18, kunalganglani.com 2026-06-22 — attempt caps (5–10), keep passes <40k tokens.
- ralphloop.sh 2026-03-19 — `<promise>BLOCKED:reason</promise>` as a distinct exit.

## Task-spec templates and sizing
- compound-engineering ce-plan plan-sections.md — Goal Capsule (objective, means, authority, stop conditions), Product Contract, Planning Contract, Implementation Units "sized so each is independently executable", Verification Contract (repo-specific commands), Definition of Done.
- obra/superpowers writing-plans — every step "code or command + expected output"; verification-before-completion skill.
- github/spec-kit — "Independent Test" per story; SC-00x measurable criteria; tests optional.
- aihero.dev/skills-to-tickets (Pocock 2026-08-24) — ticket = tracer bullet, fits one fresh context (~100k "smart zone"), "what can I demo when this is done?"; dispatch = count unblocked tickets, open that many sessions.
- docs.devin.ai — tasks ≤3 hours of human work; explicit success criteria; make decisions for it.
- docs.github.com Copilot coding agent best practices — problem, acceptance criteria, which files; avoid cross-repo, prod/security/auth, ambiguous.
- learn.chatgpt.com/guides/best-practices — Goal / Context / Constraints / Done when.
- openai/symphony SPEC.md — max_turns 20, max_concurrent_agents 10, priority dispatch, handoff state Human Review.
- gastownhall/beads AGENTS.md — bd ready → --claim → close; acceptance/design/notes fields.

## Dispatch, harvest, capacity
- code.claude.com/docs/en/claude-projects (beta 2026-09-17) — paste task list → thread per task; Overview buckets Ready for review / Waiting on you / Working / Landing / Idle / Resolved; 200 threads/day; threads park at limit and auto-resume.
- code.claude.com/docs/en/commands — /batch decomposes into 5–30 worktree subagents.
- compound-engineering /triage (older) — findings as issue cards, P1/P2/P3, yes/next/custom, "DO NOT CODE ANYTHING DURING TRIAGE"; ce-code-review report-only.
- code.claude.com/docs/en/code-review — ~20 min, $15–25/review, never blocks merge.
- Register Spill #95 (Ball 2026-08-16) — "irrefutable proof": narrated video/diagrams; spot checks + architecture.
- PR Lens 2026-08-26 — ~40 min human sign-off per change.
- claude-overnight (2026-07-27) — don't start >20% of the 5-h window, stop at 60%, skip if weekly >80%.
- shareuhack 2026-07-15 — check 5 min after launch, then sweep every 15–20 min on hook notifications.
- calv.info 2026-02-17 — 3–4 Codex tasks before bed, review in the morning.

## Tooling verdict
No first-party or marketplace skill generates a /goal condition (claude.com/plugins: 24 plugins, none). Closest: superpowers writing-plans (command + expected output per step, no cap), OpenSpec /opsx:propose (one-shot intent → SHALL/WHEN-THEN, no runner), ralph-wiggum (hard cap, no fence, self-declared completion). `/g` fills the gap; it borrows the /goal grammar, Codex's stop clause, superpowers' command+expected-output shape.
