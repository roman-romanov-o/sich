# Sich promotion plan

Goal: first ~1000 users. Researched 2026-10-24 (raw findings with sources:
`research-2026-10-24.json`). Re-read each list's CONTRIBUTING file right before
submitting — rules change.

Legend: **[A]** agent does it · **[A→H]** agent drafts, human approves/sends ·
**[H]** human only (own account, credentials, posting).

Exit criterion of each phase is listed; don't start a phase until the previous
one's exit holds.

---

## Phase 0 — Make the landing worth landing on (≈1–2 days)

Every later channel sends people to the README and the release. Fix them first.

| # | Task | Who | Done when |
|---|------|-----|-----------|
| 0.1 | Sign with Developer ID + notarize + staple in the release workflow (cert `.p12` + App Store Connect API key from the MacBook Air → repo secrets). Ship a DMG. | [A→H] secrets export/upload is human-approved | `spctl -a -vv Sich.app` says *accepted, Notarized Developer ID* on a fresh download |
| 0.2 | Create `roman-romanov-o/homebrew-tap` with a `sich` cask pointing at the release DMG; release workflow bumps it. | [A→H] | `brew install --cask roman-romanov-o/tap/sich` works on a clean machine |
| 0.3 | 20–30 s demo GIF/MP4 at the top of README: agents running → card jumps to "needs you" → drill in → quota gauge. Use the synthetic-demo screenshot script as a base. | [A] records, [H] approves cut | GIF < 8 MB, renders on GitHub |
| 0.4 | README rewrite: one-line value prop that names the differentiators ("the only board that shows your Claude subscription vs API quota and refuses to burn API credits"), install via brew first, `xattr` instructions removed, a **"Coming from Vibe Kanban?"** section, comparison table vs Vibe Kanban / Kanban Code / Conductor / cmux / Claude Squad. Keep claims about competitors factual and dated. | [A→H] | PR merged |
| 0.5 | GitHub settings: description containing "Claude Code", "Codex", "kanban", "macOS"; homepage → landing page (0.6) once it exists; topics add `vibe-kanban-alternative`, `ai-coding`, `libghostty`, `coding-agents`, `tmux`; upload a 1280×640 social preview. | [A] via `gh repo edit` (social preview upload is [H], web UI only) | `gh repo view` shows new metadata |
| 0.6 | Landing page on GitHub Pages (`/docs` or `gh-pages`): hero GIF, install command, feature sections, and three static comparison pages: `/vibe-kanban-alternative`, `/kanban-code-alternative` (macOS 14+, multi-harness), `/claude-code-quota-monitor`. Plain HTML, honest tables, `<title>`/meta/OG tags, FAQ blocks phrased as the questions people ask LLMs. | [A→H] | Pages live, indexed in Google Search Console ([H] verifies domain) |

**Exit:** signed release + tap + GIF README + landing page live.

## Phase 1 — Free listings with no star gate

Measured odds (PR/issue history pulled 2026-10-25, data in `list-stats-2026-10-25/`):

| List | Accepted | Time to decision | Notes |
|------|----------|------------------|-------|
| awesome-libghostty | ~85% merged | median ~1 day, p90 ~4 days | small, active maintainer |
| awesome-cli-coding-agents | ~63% accepted (PRs are *closed*, entries added in maintainer batch commits) | median 10 days, p90 23 | rejects GUI-only tools without a terminal interface, and closes "spray" submitters (many lists within minutes) |
| awesome-mac | ~15% merged; ~80% never touched | merged ones: median <1 day | ~28 PRs/day in, ~3/day merged; PRs editing 1 file merge at 4%, all-four-READMEs at 17% |
| awesome-claude-code | ~6% approved (≈13% in Sep) | median 4 days once approved; median open submission is 106 days old | form-only, human-filed |

Stagger submissions (one list every few days, never a burst), because
bradAGI explicitly rejects tools whose authors spray many lists at once. In the
bradAGI PR, say what the terminal side is (real PTY sessions, a CLI hook
integration), so it doesn't get read as GUI-only.

| # | Target | Rules that matter | Who |
|---|--------|-------------------|-----|
| 1.1 | [Uzaaft/awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty) → *AI Tools & Agent Orchestration* | libghostty-related ✔; alphabetical; `- [Sich](url) - Sentence-case description.`; Conventional Commit (`feat: add Sich`); **tiny PR body** — the CONTRIBUTING has an anti-LLM trap, verbose PRs get closed | [A→H] |
| 1.2 | [bradAGI/awesome-cli-coding-agents](https://github.com/bradAGI/awesome-cli-coding-agents) → *Harnesses & orchestration › Session managers & parallel runners* | no star minimum; name + link + star count + 1–2 lines; star-sorted | [A→H] |
| 1.3 | [jaywcjlove/awesome-mac](https://github.com/jaywcjlove/awesome-mac) → Developer Tools / Terminal | one entry per PR; alphabetical; AP title case; **add to all four READMEs** (en/zh/ja/ko); AI-assisted PRs welcome if rules followed | [A→H] |
| 1.4 | [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) | **Issue web form only, filed by a human, no PRs, no `gh`** — breaking it risks a ban. Eligible now (repo is >14 days old with active development). One plain line, no pitch, no emoji. | [A] drafts fields → [H] files |
| 1.5 | AlternativeTo: list Sich, mark as alternative to Vibe Kanban, cmux, Conductor, Claude Squad. The Vibe Kanban page has only 4 weak alternatives. | [A] drafts text → [H] submits from own account |
| 1.6 | Ask the authors of the "best tools 2026" articles (amux, nimbalyst, crystl, codeagentswarm, superset, agentsroom) to add Sich. These pages get cited in LLM answers. One short email each, with a link to the comparison page. | [A] drafts → [H] sends |

**Exit:** 1.1–1.3 PRs open, 1.4–1.6 sent. Merges can land later.

## Phase 2 — One concentrated launch week

Bunch everything into 3–4 days. Trending (OSS Insight, and probably GitHub's
own) ranks by star *velocity*, not totals.

| # | Task | Who |
|---|------|-----|
| 2.1 | **Show HN**, Tue–Thu morning US Eastern. Title draft: *"Show HN: Sich – a macOS kanban where every card is a live Claude Code/Codex terminal (libghostty)"*. First comment: why you built it, pool-firewall story, what's not done yet. Expect tens of stars typical; the research mean is +121/24 h, but the distribution is long-tailed. | [A] drafts → [H] posts and answers comments for 3–4 h |
| 2.2 | Same day or next: X + Bluesky thread with the GIF; tag @mitchellh / Ghostty folks for the libghostty angle (one tag, no begging). | [A] drafts → [H] posts |
| 2.3 | Reddit, spread over 2–3 days, each post framed for its sub: r/ClaudeAI and r/ClaudeCode (quota + firewall), r/macapps (native app, free/MIT), r/commandline (libghostty + tmux remote). **Check each sub's self-promo rules first**; the research could not verify them. | [A] checks rules + drafts → [H] posts |
| 2.4 | Ghostty Discord / GitHub Discussions "show and tell". | [A] drafts → [H] posts |
| 2.5 | Ship a small release (v0.2.1) during the week, so the repo shows activity to visitors. | [A] |

**Exit:** launch week done; record the star/traffic numbers (GitHub Insights → Traffic) in `docs/promotion/log.md`.

## Phase 3 — Gated and compounding

| # | Task | Gate | Who |
|---|------|------|-----|
| 3.1 | Official `homebrew/cask` PR | 225 stars self-submitted (or 75 if a third party submits); signed + notarized | [A→H] |
| 3.2 | Product Hunt | after the HN numbers are known; unverified value for OSS tools | [A] drafts → [H] launches |
| 3.3 | Technical posts, one per 2–3 weeks: "Embedding libghostty in an AppKit kanban", "How the pool firewall stops headless API spend", "Running 8 agents without missing a prompt" (your OPERATING-RULES). Cross-post to dev.to/HN/Reddit and send to newsletters (Console.dev, iOS Dev Weekly, Changelog news). | none | [A] drafts → [H] edits voice + publishes |
| 3.4 | Answer "how do I track multiple Claude sessions" threads on Reddit/GitHub issues with a GIF reply (genuine help only, never a pitch). | ongoing | [H] |
| 3.5 | Every release: a clip on X/Bluesky + changelog entry. | ongoing | [A] drafts → [H] posts |
| 3.6 | Monthly: re-check competitor status (Vibe Kanban community fork, Kanban Code macOS requirement), update comparison pages, check whether Sich shows up when ChatGPT/Claude/Perplexity are asked "best Claude Code kanban macOS". | monthly | [A] |

## Not verified by the research (treat as best practice, not evidence)

Product Hunt value, subreddit rules, GitHub topic/README SEO, GEO/LLM-answer
tactics, MacUpdate/Setapp. Setapp is a poor fit (paid curation for paid apps);
skip MacUpdate unless the tool is already getting signups.
