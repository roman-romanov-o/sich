# Code Change: QuotaUsageReader (native quota source reads)

**Status:** Draft
**Last Updated:** 2026-06-26

## Overview

A `GhostlingCore` type that produces the `[QuotaSourceInput]` the existing `QuotaProjection`
consumes — read **in-process** from `~/.claude/projects/**/*.jsonl`, replacing the Python
`jsonl_usage` + `live` pair and the `GET /quota` HTTP wire. The projection is unchanged; only the
source of its input changes from "decode HTTP body" to "read disk."

## Methods

### `QuotaUsageReader.read(now:projectsDir:) -> [QuotaSourceInput]`

**Description:** The whole job, mirroring `live.build_quota_response().sources` mapped to inputs.
Walks the transcripts, ages usage to the 5h window + weekly cap, and assembles four sources.

**Input:**
```
now: Date                 // injected clock (no inline system-clock read — testability)
projectsDir: URL = ~/.claude/projects   // overridable for fixtures
```

**Output:** exactly four `QuotaSourceInput`, in this order, **never netted**:
```
[0] provider:"anthropic" pool:"interactive"        // estimated (inferred:true) from JSONL
[1] provider:"anthropic" pool:"agent_sdk_credit"   // state: unknown  (not locally observable)
[2] provider:"codex"     pool:"codex"              // state: unknown
[3] provider:"gemini"    pool:"gemini"             // state: unknown
```

**Interactive reading semantics (must match Python):**
- Sum `input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens` on
  each record where `type == "assistant"` and `message.usage` is present.
- Keep events with `timestamp >= now - 7d` (weekly lookback); window math ages to the 5h window.
- `remainingFraction` from window cap; weekly cap dominates when binding; `reset` = sooner of
  window/weekly reset, at **whole-second** resolution. `inferred = true` always (the cap is an
  estimate).
- Caps overridable: `GHOSTLING_WINDOW_CAP_TOKENS` (default 200_000_000),
  `GHOSTLING_WEEKLY_CAP_TOKENS` (default 800_000_000).

**Helpers (single-responsibility, ≲50 lines each):**
```
parseUsageEvent(record) -> UsageEvent?   // one JSONL record → event, or nil (skip)
eventsInFile(url, since) -> [UsageEvent]  // one transcript; skips malformed lines, no whole-file drop
readUsageEvents(now, projectsDir) -> [UsageEvent]   // glob + filter to lookback
```

**Errors / degradation (honest, US-002 AC3):**
| Condition | Behavior |
|-----------|----------|
| `projectsDir` absent | interactive source = real-zero usage (fresh), not `unknown` |
| unreadable file | skip that file, keep the rest |
| malformed JSON line | skip that line, keep the rest of the file |
| non-local pool | `state: unknown` (never 0, never 100%) |

## Wiring (app side)

`QuotaSidecar.swift`'s `QuotaPoller` (HTTP GET on a timer) is replaced by a `Timer` that calls
`QuotaUsageReader.read(now:)` and hands the result to the same sink the projection already feeds.
`SidecarProcess` is deleted. No code references `127.0.0.1:8787/quota`.

## Related
- **User Stories:** US-002 (this), US-001 (single binary), US-004 (deletes the Python it replaces).
- **Decisions:** DD-001.
- **Tests:** TC-UNIT-301..303, TC-INT-301..303.
