# Producer Tests

The event producer is `.claude/scripts/ghostling-forward.sh` — a stateless bash
appender, not Swift. Its one testable behaviour is **rotation/bounding**, driven
from `pytest` via subprocess (the repo already runs pytest for the Python core).

> The producer deliberately does **not** stamp `seq` or `occurred_at` — it stays
> a ~15-line O_APPEND appender. Ordering is the consumer's job (via `timestamp`).
> This spec only covers keeping the log bounded.

## TC-PROD-005 — forwarder rotates past the size threshold, keeps the log bounded
- **Given** `events.jsonl` at/over the configured size threshold
- **When** the forwarder appends another event
- **Then** the live log is rotated to `events.jsonl.1` and the live file is re-created bounded (below threshold); no appended event is lost across the rotation, and the reader (TC-UNIT-003) picks up the new inode.
- **Symbol:** `tests/unit/test_forward_rotation.py::test_forwarder_rotates_past_threshold`
- **Pairs with** TC-UNIT-003 (reader-side inode reset) — producer rotates, reader survives it.
