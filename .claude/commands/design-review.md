# /design-review

Capture how the **shipping `sich` app looks right now** and get a structured
design critique from the `designer` agent. Two steps: capture → critique.

`$ARGUMENTS`, if given, is an extra focus for the critique (e.g. `terminal` or
`quota panel`).

## Step 1 — Capture

Run `.claude/scripts/design-review-capture.sh` (Bash). It regenerates faithful
screenshots of the current build via the E2E harness:

- `app/.artifacts/e2e/01-board.png` — the resting board (columns × flow lanes, cards, quota panel)
- `app/.artifacts/e2e/02-drillin-terminal.png` — a drilled-in live terminal (colour-check seeded)
- `app/.artifacts/e2e/03-back-to-board.png` — returned to the board

`screencapture` is used when Screen Recording is granted, else the permission-free
`CALayer.render` fallback — both are faithful (our UI is custom Core-Graphics `draw(_:)`).
If the script fails to produce PNGs, fix that before critiquing — do **not** critique stale shots.

## Step 2 — Critique (designer agent)

Spawn the `designer` agent (Agent tool, `subagent_type: designer`). The brief MUST say:

> These three PNGs are screenshots of the **REAL shipping AppKit build**, not a mockup
> to redesign. Do **NOT** build an HTML mockup or write design docs. **Read all three
> screenshots**, then run your own three rubrics against the actual pixels and return a
> **prioritized, actionable fix list**:
>
> 1. **Constraint check** (`research/14-ui-mockup-critique.md`) — any 🔴 is a
>    product-altitude bug (wrong board, resident terminal, single Claude gauge, etc.).
> 2. **Acceptance criteria** — US-002 (drill-in), US-003 + US-005 (board + attention),
>    US-006 (capacity brain): is each visibly satisfied **in the pixels**?
> 3. **Design principles** — altitude correct; amber/red unmissable when resting;
>    cards carry flow+pool+state(+`iter·phase` for Flow-A); capacity brain leads with a
>    **recommendation**, not a passive meter; density (6–7 cards); contrast ≥ 4.5:1.
>
> Also give a **cmux-parity read** on the drill-in terminal (colour, real cursor, window
> use). For every finding: **severity** (🔴/🟡/🟢), **what's wrong in the screenshot**, and
> the **concrete AppKit fix** (the `app/Sources/SichApp/*.swift` file/seam to change).
> Return the findings as a ranked list; a short written summary is enough — no JSON ceremony.

Pass the three screenshot paths and any `$ARGUMENTS` focus into the prompt.

## Step 3 — Relay

Summarize the designer's ranked findings back to the user: the 🔴s first, then 🟡s,
each with the one-line fix. Do not start implementing fixes unless asked.
