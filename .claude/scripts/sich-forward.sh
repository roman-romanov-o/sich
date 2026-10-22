#!/usr/bin/env bash
# Forward this Claude Code hook event to the Sich board via an observe-only
# append-only file sink (DD-002). The hook event JSON arrives on stdin and is
# appended verbatim as ONE newline-terminated line to the event file; the app
# tails that file (no server, no port, no reply).
#
# Watcher discipline: this only OBSERVES a human-launched session — it never spawns
# anything, never reads back, never blocks. A single append under O_APPEND is atomic
# per line so concurrent agents don't tear each other's lines. Always exit 0 so a
# write hiccup can never slow or fail the watched session.
# ponytail: append only; the app does all parsing/reconciliation.
#
# Rotation (US-001 AC3): after appending, if the live log crosses a size threshold it
# is moved aside to `<file>.1` (one retained generation, like cmux's events.jsonl.1)
# so the live file the app tails stays bounded. This stays STATELESS — no `seq`,
# no `occurred_at` stamping (a per-hook appender can't produce a global monotonic
# counter; ordering uses the event's own `timestamp`) — and best-effort: any failure
# still exits 0. The reader survives the rotation by inode (HookEventTail.resolveStart).
file="${SICH_EVENTS_FILE:-$HOME/.sich/events.jsonl}"
max_bytes="${SICH_EVENTS_MAX_BYTES:-5242880}"   # 5 MiB default
mkdir -p "$(dirname "$file")" 2>/dev/null
# Identity binding: when this session runs inside a Sich-owned pty, the app
# put SICH_CARD_ID (the board card's UUID) in the environment; stamp it onto
# the JSON line so the board can bind the session to its card even when several
# task cards share one project dir. Injected only when the line ends like a JSON
# object; anything else is appended verbatim. Still one atomic O_APPEND write.
line=$(cat)
if [ -n "$SICH_CARD_ID" ]; then
    case "$line" in
        *\}) line="${line%\}},\"sich_card_id\":\"$SICH_CARD_ID\"}" ;;
    esac
fi
printf '%s\n' "$line" >> "$file" 2>/dev/null

size=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
if [ "${size:-0}" -gt "$max_bytes" ] 2>/dev/null; then
    mv -f "$file" "$file.1" 2>/dev/null
fi
exit 0
