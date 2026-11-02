# How popular repos use GIFs and video in their README (2026-11-02)

Data: `scan.py` → `scan.json` (README media of 33 popular terminal / macOS / agent-tool repos),
`gif-stats.json` (size, length, dimensions of every GIF they embed).

## Patterns
1. **One hero above the fold.** It sits right under the title or logo: claude-code `demo.gif`,
   Warp, Ghostty and Rectangle videos, atuin, gh-dash and lazydocker GIFs. About half of the big
   repos (opencode, codex, zed, AeroSpace, Maccy) show only a static screenshot or nothing.
2. **Feature section = heading + one sentence + one clip.** lazygit (15 `###` features, one video
   each), Loop (hero GIF + 7 feature videos), posting (hero + 4 feature GIFs), gum (13 GIFs, one per
   subcommand), vhs (25 tiny GIFs). cmux, orca and vibe-kanban use screenshots per feature instead.
3. **GIF autoplays, `<video>` doesn't.** The GitHub video player shows a poster frame and needs a click.
   Repos that want motion without a click (posting, gum, gh-dash) use GIFs; repos with many clips
   (lazygit, Loop) use videos so the page stays light.

## Numbers
| | length | size | width |
|---|---|---|---|
| hero GIFs (claude-code, starship, superfile, gh-dash, atuin, lazydocker, Loop) | 9–42 s, median ~12 s | 0.4–18 MB, typically 2–5 MB | 1270–1920 px |
| feature GIFs (posting, gum) | 5–19 s, typically ~10 s | 0.05–5 MB | 800–1920 px |
| **Sich `assets/promo.gif`** | **56 s** (longest in the set) | 7.9 MB | **800 px** (lowest) |

GitHub limit: 10 MB per image/GIF; 10 MB per video on free plans (100 MB on paid plans).

## Recommendation for Sich
- Keep one hero, but cut it to ~20 s around the pitch: focus block → held questions → break →
  ⌃Tab through them. Render it at ≥1200 px. Link the full 56 s tour as an MP4 below it.
- Promote 3–4 table rows to `###` feature sections, each with a 6–12 s autoplaying GIF (≤3 MB):
  ⌃Tab switcher, backlog pull when NEEDS YOU is empty, the real terminal in a card, remote
  cards. Quota and the board shape stay as screenshots or table rows.
- Every clip already exists as a beat range in `promo/public/beats.json`, so these are new
  Remotion compositions over the same footage, not new recordings.
