# DD-002: Hook transport = observe-only append-only file sink, not an in-app server

**Status:** Accepted
**Last Updated:** 2026-06-26

## Context

Removing the sidecar (DD-001) raises the question: how do hook events reach the app without the
`127.0.0.1:8787` HTTP receiver? The instinct is "make the Swift app the server instead." But the
detector is **observe-only** — it never replies to a hook. `ghostling-forward.sh` already discards
the response and always `exit 0`; the endpoint's reply is thrown away. A request/response server is
therefore solving a problem we don't have, while keeping the port-collision class (`EADDRINUSE`)
that motivated removing the sidecar in the first place.

## Decision

Hooks deliver via an **append-only file sink**. The installed hook command **atomically appends**
the event JSON as one newline-terminated line to a known file (e.g. `~/.ghostling/events.jsonl`).
The app **tails** that file from a persisted byte offset, normalizes each line, and reconciles it
into the `SessionRegistry`. There is **no listener, no port, no reply**. The file is append-only to
the writer and read-only to the app.

## Rationale

- **Matches the observe-only nature exactly** — one-way data, one-way transport.
- **Survives the app being down** — events queue in the file and drain on next launch (an HTTP/socket
  server drops everything sent while it isn't listening).
- **No port, no `EADDRINUSE`, no health probe** — deletes the exact class DD-001 is removing.
- **Multi-tool for free** — any agent that can run a shell hook can append a line; US-005 becomes
  "more event-name mappings," not "more servers."
- **Atomic by construction** — a single `O_APPEND` `write` of one short line is atomic on local
  filesystems, so concurrent agents don't tear each other's lines.

## Alternatives Considered

1. **In-app HTTP server (move `http.server` into Swift)**
   - Pros: smallest change to the forwarder (still `curl`); familiar.
   - Cons: re-introduces a bound port + `EADDRINUSE` — the thing we're deleting; loses events while
     the app is down; a server for data that needs no reply. Rejected.

2. **Unix domain socket**
   - Pros: no TCP port; local-only by nature.
   - Cons: requires the app to be **listening** at hook time — events fired while the app is closed
     are lost; more moving parts than a file append. Rejected.

3. **Tail the Claude JSONL transcripts directly (no hook forwarder at all)**
   - Pros: zero install step.
   - Cons: JSONL is a *secondary, lower-confidence* signal (the existing `jsonl_tail` is a fallback,
     not the primary); it's Claude-only, killing the multi-tool unlock; and it can't express
     "waiting on you" (`Notification`) cleanly. Kept as the existing fallback, not the primary.

## Consequences

- **Positive:** no server/port; durable across app restarts; one writer-format serves all agents.
- **Negative:** at-least-once semantics on resume — the app must persist a byte offset and handle
  rotation/truncation (offset > size → reset) and partial trailing lines (consume to last newline).
  These are the US-003 edge cases.
- **Neutral:** the event file grows unbounded until rotated; a size cap / periodic truncate is a
  later concern (`ponytail:` add when it actually grows large).

## Related

- **User Stories:** US-003 (the sink), US-005 (many writers, one file).
- **Other Decisions:** DD-001 (this is its transport half).
- **Replaces:** `server/endpoint.py` `/hooks` POST route and the `curl` in `ghostling-forward.sh`.
