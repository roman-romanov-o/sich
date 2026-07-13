# Research

Technical research and codebase analysis for TASK-09 (Calendar Integration).

**Date:** 2026-07-08 · **Status:** Complete

## Contents

| # | Report | One-line finding |
|---|--------|------------------|
| 01 | [What "calendar integration" means here](01-what-calendar-integration-means-here.md) | The repo already defines it: task-06's read-only free/busy adapter (Phase B) + manual free-until (Phase A). Not meetings UI, not sync, not effort capture (task-02 DD-001 rejected that). Zero calendar code exists today. |
| 02 | [Existing time/capacity surfaces](02-existing-time-and-capacity-surfaces.md) | Quota gauges already model "capacity refills at a future Date"; the availability signal mirrors that shape. Integration seams exist: `QuotaGaugeRow` reset lines, `QuotaAdvisor.recommend`, the `NativeQuotaPoller` in-process ingestion pattern. |
| 03 | [Calendar source options & packaging](03-calendar-source-options-and-packaging.md) | EventKit wins (covers Google accounts via macOS Calendar; no OAuth/webview/network). Blocking unknown: ghostling is an unbundled `swift run` binary with no Info.plist — TCC calendar consent needs a spike, likely a `.app` wrapper. `macos-flow` has NO calendar code (assumption corrected). |
| 04 | [Scoping assessment & risks](04-scoping-assessment-and-risks.md) | Well-founded only as the narrow "human availability signal" slice; ship manual free-until first, EventKit behind a GO/NO-GO spike; policy stays in task-06. |

## Critical assessment

**Proceed, but re-scope the name's ambition down.** The task is legitimate — the capacity
panel today advises launches while blind to the human's next hard boundary, which is the
product's own single-threaded-human thesis — but "Calendar Integration" must be pinned to
the already-specified contract (task-06 §6.2: free/busy intervals only, freshness-labeled,
read-only) or it will drift into one of three forbidden products: a meeting manager,
a 2-way sync, or a calendar-based effort tracker.

Corrections to going-in assumptions:

1. **`macos-flow` is not a calendar engine.** It is a Pomodoro engine plus an
   *unimplemented Todoist-sync blueprint*; nothing there shortcuts this task. Its only
   relevance is the DD-002 loose-coupling precedent and its example of a properly
   bundled/entitled macOS app.
2. **The biggest risk is not calendar logic but packaging.** EventKit code is trivial;
   TCC consent for an unbundled SwiftPM executable (no Info.plist, no bundle, prompt
   attributed to the invoking terminal under `swift run`) is unverified and version-
   fragile. A Phase-0 spike (like libghostty's Phase 00) must gate the EventKit path;
   the manual free-until input is the permission-free deliverable that ships regardless.
3. **Ordering dependency:** the full consumer of this data (task-06's advisor) is still
   in Review and unimplemented. Task-09 must carry its own visible surface (availability
   row in the capacity panel + a `QuotaAdvisor` boundary check) or it repeats the
   green-but-unreachable failure documented in project memory.

## Open questions for the operator (before /saha:task)

1. Is your working calendar (Google?) added to macOS Calendar.app / Internet Accounts?
   (If not and it never will be, the EventKit recommendation weakens.)
2. Should the `.app`-bundle step, if the spike demands it, live inside task-09 or as
   its own task?
3. Confirm the scope cut: manual free-until + read-only free/busy + panel row + advisor
   awareness — with recommendation *policy* deferred to task-06.
