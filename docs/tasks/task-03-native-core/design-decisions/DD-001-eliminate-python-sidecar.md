# DD-001: Eliminate the Python sidecar — port the remaining I/O to Swift

**Status:** Accepted
**Last Updated:** 2026-06-26

## Context

The app ships two languages and two processes: a Swift/AppKit front end and a Python sidecar
(`src/mission_control`, a stdlib `http.server` on `127.0.0.1:8787`) that the Swift app spawns and
polls. But most of the "Python logic" is **already duplicated in Swift**: the quota *projection*
runs natively (`QuotaProjection`), which is why `live.py` only ships raw `SourceReading`s over the
wire. Auditing what is *genuinely* Python-only leaves just two things:

1. **Quota source reads** — globbing `~/.claude/projects/**/*.jsonl`, summing token usage, aging it
   to a 5h window + weekly cap (`quota/jsonl_usage.py` + the assembly half of `quota/live.py`).
2. **Hook intake** — receiving hook POSTs and reconciling them (`server/` + `detector/`).

Both are small and dependency-light (Pydantic + stdlib, zero exotic I/O). The sidecar's costs are
real and recurring: a second runtime to install, process supervision, and a localhost port we have
already been bitten by (`SidecarProcess.isHealthy()` exists solely to dodge `EADDRINUSE`). cmux —
the same Swift/Ghostty stack — ships as **one binary**; we can too.

## Decision

**Port the two remaining I/O pieces into `GhostlingCore` and delete `src/mission_control`.** Quota
source readings are produced in-process by a Swift `QuotaUsageReader` feeding the existing
`QuotaProjection`; hooks arrive through an observe-only file sink (DD-002) and reconcile into the
Swift `SessionRegistry`. The HTTP server, the `/quota` and `/sessions` polling, and the Python
package are removed. Deletion is **parity-gated** (US-004): no Python file is deleted until its
behavior is green in `swift test`.

## Rationale

- **Most of the work is already done** — only the JSONL walk + window aging and the hook
  normalize/reconcile remain; the projection (the subtle part) is native already.
- **Removes a whole failure class** — no port, no `EADDRINUSE`, no "is the sidecar up?" probe, no
  two-language deploy. Fewer moving parts at 3am.
- **Single binary = product parity with cmux** and a clean install story for distribution.
- **Watcher discipline is untouched** — we are removing an HTTP *server*, not adding a spawn path;
  the core still only observes.

## Alternatives Considered

1. **Keep the sidecar as-is**
   - Pros: zero work; the logic is tested in Python.
   - Cons: two runtimes forever; port collisions; the projection is *already* duplicated, so we pay
     the two-language tax for a shrinking amount of unique Python. Rejected.

2. **Bundle a frozen Python interpreter (PyInstaller / embedded)**
   - Pros: reuse the Python verbatim; no re-port.
   - Cons: tens of MB of interpreter in the app bundle, signing/notarization pain, still a second
     process and a localhost port. Heavier than the code it preserves. Rejected.

3. **Port quota only; keep a tiny hook server**
   - Pros: smaller diff.
   - Cons: still a process + a port for the one thing (hooks) that needs *no* reply — see DD-002.
     Leaves the `EADDRINUSE` class in place. Rejected in favor of the full elimination.

## Consequences

- **Positive:** one language, one binary, no port; smaller attack/ops surface; trivial multi-tool
  extension (US-005) once hooks are file-based.
- **Negative:** the 66 pytest cases stop being the source of truth — their behavior must be
  re-pinned in `swift test` first (US-004 parity gate). Swift gains file-tailing + JSONL-walk I/O
  it didn't have.
- **Neutral:** `research/UI_POC.html` and the docs still describe a "sidecar"; update references as
  they're touched, not in a big-bang doc sweep.

## Related

- **User Stories:** US-001, US-002, US-003, US-004, US-005.
- **Other Decisions:** DD-002 (the transport half of this); task-01 DD-001 (pool firewall, unchanged).
- **Memory:** [[python-sidecar-built-iter1-3]], [[real-prototype-assembled-data-paths-live]],
  [[cmux-detection-is-hooks-not-terminal-scraping]].
