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

# Per-turn review data. The three fields are read with POSIX sed rather than
# macOS' bundled property-list tool: this same script is installed on Linux
# hosts (US-002), where that tool does not exist and every extraction failed
# silently — gating the whole block below, so diffs were dropped while the raw
# append still succeeded. For the same reason every tool here is resolved
# through PATH, never by an absolute macOS path. git runs in the repo that owns
# the hook, so remote sessions ship the resulting unified diff as data and the
# board never needs their filesystem.
json_field() {
    printf '%s' "$line" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}
event=$(json_field hook_event_name)
session=$(json_field session_id)
cwd=$(json_field cwd)
if [ -n "$session" ] && [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    safe_session=$(printf '%s' "$session" | tr -cd '[:alnum:]_.-')
    state_dir="${SICH_DIFF_STATE_DIR:-$HOME/.sich/turn-diffs}/$safe_session"
    mkdir -p "$state_dir" 2>/dev/null

    # Add intent-to-add entries only while taking the snapshot/diff so untracked
    # text appears in unified output without staging or otherwise changing the
    # operator's index.
    snapshot_with_untracked() {
        git_dir=$(git -C "$cwd" rev-parse --git-dir 2>/dev/null) || return
        case "$git_dir" in /*) index="$git_dir/index" ;; *) index="$cwd/$git_dir/index" ;; esac
        backup="$state_dir/index.$$"
        had_index=0
        if [ -f "$index" ]; then cp "$index" "$backup" 2>/dev/null && had_index=1; fi
        git -C "$cwd" add -N -A >/dev/null 2>&1
        "$@"
        result=$?
        if [ "$had_index" -eq 1 ]; then mv "$backup" "$index" 2>/dev/null
        else rm -f "$index" "$backup" 2>/dev/null
        fi
        return "$result"
    }

    if [ "$event" = "UserPromptSubmit" ]; then
        iteration=$(cat "$state_dir/iteration" 2>/dev/null)
        iteration=$((${iteration:-0} + 1))
        printf '%s' "$iteration" > "$state_dir/iteration"
        snapshot_with_untracked sh -c \
            'base=$(git -C "$1" stash create "sich-turn-$2"); \
             if [ -z "$base" ]; then base=$(git -C "$1" rev-parse HEAD 2>/dev/null); fi; \
             printf "%s" "$base" > "$3"' \
            sh "$cwd" "$iteration" "$state_dir/checkpoint"
        if [ "$iteration" -eq 1 ]; then
            cp "$state_dir/checkpoint" "$state_dir/session-checkpoint" 2>/dev/null
        fi
    elif [ "$event" = "Stop" ] && [ -s "$state_dir/checkpoint" ]; then
        checkpoint=$(cat "$state_dir/checkpoint")
        iteration=$(cat "$state_dir/iteration" 2>/dev/null)
        diff_path="$state_dir/diff.$$"
        snapshot_with_untracked sh -c \
            'git -C "$1" diff --no-ext-diff --binary "$2" > "$3"' \
            sh "$cwd" "$checkpoint" "$diff_path"
        if [ -s "$diff_path" ]; then
            # Keep one append atomic and bound pathological generated/binary turns.
            max_diff_bytes="${SICH_DIFF_MAX_BYTES:-1572864}"
            diff_size=$(wc -c < "$diff_path" 2>/dev/null | tr -d '[:space:]')
            if [ "${diff_size:-0}" -gt "$max_diff_bytes" ]; then
                head -c "$max_diff_bytes" "$diff_path" > "$diff_path.trim"
                printf '\n\\ No newline: diff truncated by Sich at %s bytes\n' \
                    "$max_diff_bytes" >> "$diff_path.trim"
                mv "$diff_path.trim" "$diff_path"
            fi
            # GNU base64 wraps at 76 columns where macOS' does not; `tr -d` folds
            # either shape back into the single JSON string field.
            diff_b64=$(base64 < "$diff_path" | tr -d '\n')
            session_b64=""
            if [ -s "$state_dir/session-checkpoint" ]; then
                session_checkpoint=$(cat "$state_dir/session-checkpoint")
                session_path="$state_dir/session-diff.$$"
                snapshot_with_untracked sh -c \
                    'git -C "$1" diff --no-ext-diff --binary "$2" > "$3"' \
                    sh "$cwd" "$session_checkpoint" "$session_path"
                session_size=$(wc -c < "$session_path" 2>/dev/null | tr -d '[:space:]')
                if [ "${session_size:-0}" -gt "$max_diff_bytes" ]; then
                    head -c "$max_diff_bytes" "$session_path" > "$session_path.trim"
                    mv "$session_path.trim" "$session_path"
                fi
                session_b64=$(base64 < "$session_path" | tr -d '\n')
                rm -f "$session_path"
            fi
            cwd_b64=$(printf '%s' "$cwd" | base64 | tr -d '\n')
            card_field=""
            if [ -n "$SICH_CARD_ID" ]; then
                card_field=",\"sich_card_id\":\"$SICH_CARD_ID\""
            fi
            printf '{"sich_event_type":"turn_diff","session_id":"%s","iteration":%s,"timestamp":%s,"cwd_base64":"%s","diff_base64":"%s","session_diff_base64":"%s"%s}\n' \
                "$safe_session" "${iteration:-0}" "$(date +%s)" "$cwd_b64" "$diff_b64" "$session_b64" "$card_field" \
                >> "$file" 2>/dev/null
        fi
        rm -f "$diff_path"
    fi
fi

size=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
if [ "${size:-0}" -gt "$max_bytes" ] 2>/dev/null; then
    mv -f "$file" "$file.1" 2>/dev/null
fi
exit 0
