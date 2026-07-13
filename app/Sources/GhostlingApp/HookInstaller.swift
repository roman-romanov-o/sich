import Foundation

/// Installs the Ghostling hook forwarder into `<repoRoot>/.claude/settings.json` so
/// REAL interactive Claude Code sessions in this project surface on the board (flow
/// B) — the "no hooks in claude code" gap. The **app** does this at launch, which is
/// a different process from the agent, so it is not the self-modification the agent
/// is firewalled from doing. A faithful Swift port of
/// `.claude/scripts/enable-board-hooks.sh`: idempotent, reuses a `matcher: ""`
/// group, and preserves every hook already there (notably SessionStart's
/// welcome.sh). Best-effort — a write failure just means hooks aren't auto-wired.
enum HookInstaller {
    static let forward = "bash .claude/scripts/ghostling-forward.sh"
    /// Lifecycle events the board cares about: appear → run → wait (Stop = turn end) →
    /// done (SessionEnd = the session actually closed — the only real Done).
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "Notification", "Stop", "SessionEnd",
    ]

    /// Merge the forwarder into every board event. Returns true if the file was
    /// (re)written, false if it was already fully wired or the merge could not be
    /// done safely.
    @discardableResult
    static func install(repoRoot: URL) -> Bool {
        install(settings: repoRoot.appendingPathComponent(".claude/settings.json"),
                command: forward)
    }

    /// USER-level install: `~/.claude/settings.json` + a self-contained copy of the
    /// forwarder in `~/.ghostling/`, referenced by ABSOLUTE path. This is what makes
    /// a claude session in ANY repo (not just this one) emit hook lines — the
    /// repo-relative install above only covers projects that happen to carry the
    /// script, which broke status updates for task cards pointing at other repos.
    @discardableResult
    static func installGlobal(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let script = home.appendingPathComponent(".ghostling/ghostling-forward.sh")
        try? FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? forwarderScript.write(to: script, atomically: true, encoding: .utf8)) != nil
        else { return false }
        return install(settings: home.appendingPathComponent(".claude/settings.json"),
                       command: "bash \(script.path)")
    }

    private static func install(settings path: URL, command: String) -> Bool {
        var cfg = readConfig(path)
        var hooks = cfg["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            guard !alreadyForwarding(groups, command: command) else { continue }
            hooks[event] = appendForward(into: groups, command: command)
            changed = true
        }
        guard changed else { return false }
        cfg["hooks"] = hooks
        return writeConfig(cfg, to: path)
    }

    /// True if any group in this event already runs the forwarder — the idempotency
    /// guard that makes re-running install a no-op.
    private static func alreadyForwarding(_ groups: [[String: Any]], command: String) -> Bool {
        groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? [])
                .contains { $0["command"] as? String == command }
        }
    }

    /// Append the forwarder, reusing an existing `matcher: ""` group (e.g.
    /// SessionStart's welcome) if present, else creating one — so welcome.sh and the
    /// forwarder share a group exactly as the shell enabler produces.
    private static func appendForward(into groups: [[String: Any]], command: String) -> [[String: Any]] {
        var groups = groups
        let entry: [String: Any] = ["type": "command", "command": command]
        if let idx = groups.firstIndex(where: { ($0["matcher"] as? String ?? "") == "" }) {
            var hooks = groups[idx]["hooks"] as? [[String: Any]] ?? []
            hooks.append(entry)
            groups[idx]["hooks"] = hooks
        } else {
            groups.append(["matcher": "", "hooks": [entry]])
        }
        return groups
    }

    private static func readConfig(_ path: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let json = obj as? [String: Any]
        else { return [:] }
        return json
    }

    private static func writeConfig(_ cfg: [String: Any], to path: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(cfg),
              let data = try? JSONSerialization.data(
                  withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: path)) != nil
    }
}

/// The forwarder script, embedded so the GLOBAL install is self-contained (the app
/// can't reference a repo-relative path from arbitrary projects). Kept byte-identical
/// to `.claude/scripts/ghostling-forward.sh` — that file stays the source of truth.
private let forwarderScript = #"""
#!/usr/bin/env bash
# Forward this Claude Code hook event to the Ghostling board via an observe-only
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
file="${GHOSTLING_EVENTS_FILE:-$HOME/.ghostling/events.jsonl}"
max_bytes="${GHOSTLING_EVENTS_MAX_BYTES:-5242880}"   # 5 MiB default
mkdir -p "$(dirname "$file")" 2>/dev/null
# Identity binding: when this session runs inside a Ghostling-owned pty, the app
# put GHOSTLING_CARD_ID (the board card's UUID) in the environment; stamp it onto
# the JSON line so the board can bind the session to its card even when several
# task cards share one project dir. Injected only when the line ends like a JSON
# object; anything else is appended verbatim. Still one atomic O_APPEND write.
line=$(cat)
if [ -n "$GHOSTLING_CARD_ID" ]; then
    case "$line" in
        *\}) line="${line%\}},\"ghostling_card_id\":\"$GHOSTLING_CARD_ID\"}" ;;
    esac
fi
printf '%s\n' "$line" >> "$file" 2>/dev/null

event=$(printf '%s' "$line" | /usr/bin/plutil -extract hook_event_name raw -o - - 2>/dev/null)
session=$(printf '%s' "$line" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null)
cwd=$(printf '%s' "$line" | /usr/bin/plutil -extract cwd raw -o - - 2>/dev/null)
if [ -n "$session" ] && [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    safe_session=$(printf '%s' "$session" | tr -cd '[:alnum:]_.-')
    state_dir="${GHOSTLING_DIFF_STATE_DIR:-$HOME/.ghostling/turn-diffs}/$safe_session"
    mkdir -p "$state_dir" 2>/dev/null
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
            'base=$(git -C "$1" stash create "ghostling-turn-$2"); \
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
            max_diff_bytes="${GHOSTLING_DIFF_MAX_BYTES:-1572864}"
            diff_size=$(wc -c < "$diff_path" 2>/dev/null | tr -d '[:space:]')
            if [ "${diff_size:-0}" -gt "$max_diff_bytes" ]; then
                head -c "$max_diff_bytes" "$diff_path" > "$diff_path.trim"
                printf '\n\\ No newline: diff truncated by Ghostling at %s bytes\n' \
                    "$max_diff_bytes" >> "$diff_path.trim"
                mv "$diff_path.trim" "$diff_path"
            fi
            diff_b64=$(/usr/bin/base64 < "$diff_path" | tr -d '\n')
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
                session_b64=$(/usr/bin/base64 < "$session_path" | tr -d '\n')
                rm -f "$session_path"
            fi
            cwd_b64=$(printf '%s' "$cwd" | /usr/bin/base64 | tr -d '\n')
            card_field=""
            if [ -n "$GHOSTLING_CARD_ID" ]; then
                card_field=",\"ghostling_card_id\":\"$GHOSTLING_CARD_ID\""
            fi
            printf '{"ghostling_event_type":"turn_diff","session_id":"%s","iteration":%s,"timestamp":%s,"cwd_base64":"%s","diff_base64":"%s","session_diff_base64":"%s"%s}\n' \
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
"""#
