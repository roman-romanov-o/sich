# Research

Technical research and codebase analysis.

## Contents

- [estimation-in-the-ai-era.md](estimation-in-the-ai-era.md) — best practices for estimating tasks & managing capacity when a solo dev runs AI agents. Evidence-based (METR 2025 RCT, DORA 2025, GitHub Copilot study) + product implications.
- [poc-estimation-framework.md](poc-estimation-framework.md) — applied POC proposal: a pure `estimation/` package (cycle-time reducer → Monte Carlo forecast → two-axis capacity) over the existing signal stream, with slices S0–S3 and testable acceptance criteria.
- [work-taxonomy-and-measurement.md](work-taxonomy-and-measurement.md) — taxonomy of work-types on a task (implementation / verification / coordination / planning / wait) and how to measure each. Grounds the "do Slack & meetings count?" question in SPACE, DevEx, Flow Framework, Lean VSM, and Kanban; introduces the per-actor flow-efficiency reframe and the invisible-work problem for a watcher.
- [effort-awareness-and-attribution.md](effort-awareness-and-attribution.md) — can the product be aware of *all* effort on a task? Answers: no (and that's the right target — "no silent zeros"), reframes it as an *attribution* not capture problem, and fills the invisible-work bucket with a **Pomodoro-as-self-report** mechanism that inverts the surveillance tradeoff. Finds ~80% already built in the sibling `macos-flow` repo and lays out the loose-coupling reuse path + `EffortReading` design.
