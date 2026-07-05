# Code Changes — task-03

Interface contracts for the two ported seams. Both live in `GhostlingCore` (so they are
unit-testable without the AppKit shell) and feed the **already-existing** `QuotaProjection` /
`SessionRegistry`.

| Contract | Replaces (Python) | File |
|----------|-------------------|------|
| [Quota source reader](quota-source-reader.md) | `quota/jsonl_usage.py` + `quota/live.py` assembly + `GET /quota` wire | quota-source-reader.md |
| [Hook event sink](hook-event-sink.md) | `server/endpoint.py` `/hooks` + `server/ingest.py` + `curl` in `ghostling-forward.sh` | hook-event-sink.md |

What is **not** re-contracted (unchanged, already native): `QuotaProjection` (projection math),
`QuotaSourceInput` / `QuotaSourceReading` (Decodable types), `SessionRegistry` (session store),
and the board/quota UI.
