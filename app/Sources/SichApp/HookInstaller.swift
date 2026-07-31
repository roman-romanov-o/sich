import Foundation
import SichCore

/// Installs Sich's observe-only agent hook plumbing. Current app startup uses
/// scoped PATH shims (`~/.sich/bin/claude` and `codex`) for managed terminals;
/// the repo/global settings installers remain for legacy/manual cleanup tests and
/// preserve user hooks when used.
enum HookInstaller {
    static let forward = "bash .claude/scripts/sich-forward.sh"
    static let codexBinDirName = ".sich/bin"
    static let codexHookDirName = ".sich/hooks"
    static let codexShimName = "codex"
    static let claudeShimName = "claude"
    static let codexProfileName = "sich-hooks"
    /// Lifecycle events the board cares about: appear → run → wait (Stop = turn end) →
    /// done (SessionEnd = the session actually closed — the only real Done).
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "Notification", "SubagentStart", "SubagentStop",
        "Stop", "SessionEnd",
    ]

    /// The embedded forwarder's bytes. The remote install pushes exactly these over
    /// ssh, and the staleness probe hashes them — so this is the single source of
    /// truth for "the forwarder we ship".
    // periphery:ignore - test-only entry (scan runs with exclude_tests)
    static var forwarderBody: String { forwarderScript }

    /// Merge the forwarder into every board event. Returns true if the file was
    /// (re)written, false if it was already fully wired or the merge could not be
    /// done safely.
    @discardableResult
    static func install(repoRoot: URL) -> Bool {
        install(settings: repoRoot.appendingPathComponent(".claude/settings.json"),
                command: forward)
    }

    /// USER-level install: `~/.claude/settings.json` + a self-contained copy of the
    /// forwarder in `~/.sich/`, referenced by ABSOLUTE path. This is what makes
    /// a claude session in ANY repo (not just this one) emit hook lines — the
    /// repo-relative install above only covers projects that happen to carry the
    /// script, which broke status updates for task cards pointing at other repos.
    @discardableResult
    static func installGlobal(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let script = home.appendingPathComponent(".sich/sich-forward.sh")
        try? FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? forwarderScript.write(to: script, atomically: true, encoding: .utf8)) != nil
        else { return false }
        return install(settings: home.appendingPathComponent(".claude/settings.json"),
                       command: "bash \(script.path)")
    }

    @discardableResult
    static func uninstallGlobal(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let settings = home.appendingPathComponent(".claude/settings.json")
        let command = "bash \(home.appendingPathComponent(".sich/sich-forward.sh").path)"
        var cfg = readConfig(settings)
        guard var hooks = cfg["hooks"] as? [String: Any] else { return false }
        var changed = false
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let cleaned = groups.compactMap { group -> [String: Any]? in
                var group = group
                let before = group["hooks"] as? [[String: Any]] ?? []
                let after = before.filter { $0["command"] as? String != command }
                if after.count != before.count { changed = true }
                guard !after.isEmpty else { return nil }
                group["hooks"] = after
                return group
            }
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }
        guard changed else { return false }
        if hooks.isEmpty {
            cfg.removeValue(forKey: "hooks")
        } else {
            cfg["hooks"] = hooks
        }
        return writeConfig(cfg, to: settings)
    }

    @discardableResult
    static func installCodexShim(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let binDir = home.appendingPathComponent(codexBinDirName, isDirectory: true)
        let hookDir = home.appendingPathComponent(codexHookDirName, isDirectory: true)
        let shim = binDir.appendingPathComponent(codexShimName, isDirectory: false)
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let profile = codexHome.appendingPathComponent("\(codexProfileName).config.toml")
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            try codexWrapperScript.write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            for event in codexEvents {
                let path = hookDir.appendingPathComponent("sich-codex-\(event).sh")
                try codexHookScript(event: event).write(to: path, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            }
            try codexProfile(hookDir: hookDir).write(to: profile, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func installClaudeShim(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let binDir = home.appendingPathComponent(codexBinDirName, isDirectory: true)
        let shim = binDir.appendingPathComponent(claudeShimName, isDirectory: false)
        let forwarder = home.appendingPathComponent(".sich/sich-forward.sh")
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: forwarder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try forwarderScript.write(to: forwarder, atomically: true, encoding: .utf8)
            try claudeWrapperScript.write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: forwarder.path)
            return true
        } catch {
            return false
        }
    }

    static func codexShimPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appendingPathComponent(codexBinDirName, isDirectory: true).path
    }

    private static func install(settings path: URL, command: String) -> Bool {
        guard let patched = patched(readConfig(path), command: command) else { return false }
        return writeConfig(patched, to: path)
    }

    /// Merge the forwarder into every board event. Returns `nil` when the config
    /// is already fully wired — the idempotency answer both the local install and
    /// the remote one need, which is why it is a value and not a file write.
    static func patched(_ config: [String: Any], command: String) -> [String: Any]? {
        var cfg = config
        var hooks = cfg["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            guard !alreadyForwarding(groups, command: command) else { continue }
            hooks[event] = appendForward(into: groups, command: command)
            changed = true
        }
        guard changed else { return nil }
        cfg["hooks"] = hooks
        return cfg
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
        config(from: (try? Data(contentsOf: path)) ?? Data())
    }

    static func config(from data: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let json = obj as? [String: Any]
        else { return [:] }
        return json
    }

    private static func writeConfig(_ cfg: [String: Any], to path: URL) -> Bool {
        guard let data = configData(cfg) else { return false }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: path)) != nil
    }

    private static func configData(_ cfg: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(cfg) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Remote install (US-005)

    /// What the remote `~/.claude/settings.json` calls. `$HOME` stays unexpanded
    /// — it is the far side's home, resolved by the shell claude runs the hook
    /// in, and the same string works on every host.
    static let remoteForward = "bash \"$HOME\"/\(RemoteHookFile.forwarder.rawValue)"

    /// Install the forwarder on a remote host, mirroring ``installGlobal`` for a
    /// home directory we cannot see: push the same bytes, then patch the remote
    /// settings — preserving whatever hooks the user already had there.
    ///
    /// Adds no remote binary and no new trust surface (AC-5): what lands is the
    /// shell script the local install writes, over the ssh identity the operator
    /// already uses for this host.
    @discardableResult
    static func installRemote(spec: RemoteTmuxSpec, runner: RemoteCommandRunner) -> Bool {
        guard push(Data(forwarderScript.utf8), to: .forwarder, spec: spec, runner: runner)
        else { return false }
        guard case .bytes(let raw) = RemoteHookProbe.read(
            .claudeSettings, on: spec, using: runner) else { return false }
        guard let patched = patched(config(from: raw), command: remoteForward),
              let data = configData(patched)
        else { return true }   // already wired — the push above is the whole job
        return push(data, to: .claudeSettings, spec: spec, runner: runner)
    }

    /// The honest answer to "are our hooks on this host", read fresh every time.
    static func remoteInstallState(
        spec: RemoteTmuxSpec, runner: RemoteCommandRunner
    ) -> RemoteHookInstallState {
        RemoteHookProbe.state(
            forwarder: RemoteHookProbe.read(.forwarder, on: spec, using: runner),
            matching: Data(forwarderScript.utf8),
            settings: RemoteHookProbe.read(.claudeSettings, on: spec, using: runner),
            referencesHook: { referencesForwarder(config(from: $0)) })
    }

    /// True when the remote settings actually call our forwarder for at least one
    /// event — bytes on disk that nothing invokes are not an install.
    private static func referencesForwarder(_ cfg: [String: Any]) -> Bool {
        let hooks = cfg["hooks"] as? [String: Any] ?? [:]
        return events.contains {
            alreadyForwarding(hooks[$0] as? [[String: Any]] ?? [], command: remoteForward)
        }
    }

    private static func push(
        _ bytes: Data, to file: RemoteHookFile, spec: RemoteTmuxSpec, runner: RemoteCommandRunner
    ) -> Bool {
        guard let argv = try? RemoteTmuxCommand.installArgv(for: spec, file: file),
              let result = runner.run(argv: argv, input: bytes)
        else { return false }
        return result.succeeded
    }
}

/// Per-host install state for the board, keyed by ssh destination.
///
/// Never a "we installed once" cache: every entry is the result of a probe, and
/// a host with no probe result yet reads ``RemoteHookInstallState/unknown`` — the
/// state that says *we do not know*, which is exactly true.
@MainActor
public final class RemoteHookStatus {
    public static let shared = RemoteHookStatus()

    /// Positive opt-in, like the usage probe's: tests read and write state
    /// directly and never reach a host. Set ONLY by the real executable.
    public static var probingEnabled = false

    /// The destination whose install is in flight, if any. Read to collapse a
    /// double click: two installs racing on the same remote file could interleave
    /// their write-then-rename. Cleared when the install's probe lands, so a
    /// failed attempt can always be retried.
    private(set) var lastRequestedInstall: String?

    private var states: [String: RemoteHookInstallState] = [:]
    private var specs: [String: RemoteTmuxSpec] = [:]
    private let runner: RemoteCommandRunner

    init(runner: RemoteCommandRunner = SSHCommandRunner()) {
        self.runner = runner
    }

    /// Remember a remote card's spec and kick the first probe.
    func register(_ spec: RemoteTmuxSpec) {
        guard let destination = try? RemoteTmuxCommand.destination(for: spec) else { return }
        specs[destination] = spec
        refresh(destination)
    }

    func state(for destination: String) -> RemoteHookInstallState {
        states[destination] ?? .unknown
    }

    func setState(_ state: RemoteHookInstallState, for destination: String) {
        states[destination] = state
    }

    /// Install (or update) on demand — what an actionable chip click does.
    func requestInstall(for destination: String) {
        guard lastRequestedInstall != destination else { return }   // already in flight
        lastRequestedInstall = destination
        guard Self.probingEnabled, let spec = specs[destination] else { return }
        offMainThread { runner in
            HookInstaller.installRemote(spec: spec, runner: runner)
            return HookInstaller.remoteInstallState(spec: spec, runner: runner)
        } then: { [weak self] (state: RemoteHookInstallState) in
            self?.setState(state, for: destination)
            self?.finishInstall(destination)
        }
    }

    private func finishInstall(_ destination: String) {
        if lastRequestedInstall == destination { lastRequestedInstall = nil }
    }

    func refresh(_ destination: String) {
        guard Self.probingEnabled, let spec = specs[destination] else { return }
        offMainThread { runner in
            HookInstaller.remoteInstallState(spec: spec, runner: runner)
        } then: { [weak self] (state: RemoteHookInstallState) in
            self?.setState(state, for: destination)
        }
    }

    /// ssh blocks for as long as the network wants it to; none of that may happen
    /// on the main thread or on a cooperative-pool thread.
    private func offMainThread(
        _ work: @escaping @Sendable (RemoteCommandRunner) -> RemoteHookInstallState,
        then land: @escaping @MainActor (RemoteHookInstallState) -> Void
    ) {
        let runner = self.runner
        DispatchQueue.global(qos: .utility).async {
            let state = work(runner)
            Task { @MainActor in land(state) }
        }
    }
}

/// The forwarder script, embedded so the GLOBAL install is self-contained (the app
/// can't reference a repo-relative path from arbitrary projects). Kept byte-identical
/// to `.claude/scripts/sich-forward.sh` — that file stays the source of truth.
private let forwarderScript = #"""
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
# through PATH, never by an absolute macOS path.
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
"""#

private let codexEvents = [
    "SessionStart", "UserPromptSubmit", "Stop",
    "PreToolUse", "PostToolUse", "PermissionRequest",
    "SubagentStart", "SubagentStop", "SessionEnd",
]

private func codexProfile(hookDir: URL) -> String {
    func command(_ event: String) -> String {
        hookDir.appendingPathComponent("sich-codex-\(event).sh").path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    return """
    [features]
    hooks = true

    [[hooks.SessionStart]]
    matcher = "startup|resume"
    [[hooks.SessionStart.hooks]]
    type = "command"
    command = "\(command("SessionStart"))"
    timeout = 10

    [[hooks.UserPromptSubmit]]
    [[hooks.UserPromptSubmit.hooks]]
    type = "command"
    command = "\(command("UserPromptSubmit"))"
    timeout = 10

    [[hooks.Stop]]
    [[hooks.Stop.hooks]]
    type = "command"
    command = "\(command("Stop"))"
    timeout = 10

    [[hooks.PreToolUse]]
    [[hooks.PreToolUse.hooks]]
    type = "command"
    command = "\(command("PreToolUse"))"
    timeout = 120

    [[hooks.PostToolUse]]
    [[hooks.PostToolUse.hooks]]
    type = "command"
    command = "\(command("PostToolUse"))"
    timeout = 10

    [[hooks.PermissionRequest]]
    [[hooks.PermissionRequest.hooks]]
    type = "command"
    command = "\(command("PermissionRequest"))"
    timeout = 120

    [[hooks.SubagentStart]]
    [[hooks.SubagentStart.hooks]]
    type = "command"
    command = "\(command("SubagentStart"))"
    timeout = 10

    [[hooks.SubagentStop]]
    [[hooks.SubagentStop.hooks]]
    type = "command"
    command = "\(command("SubagentStop"))"
    timeout = 10

    [[hooks.SessionEnd]]
    matcher = "stop"
    [[hooks.SessionEnd.hooks]]
    type = "command"
    command = "\(command("SessionEnd"))"
    timeout = 10
    """
}

private let claudeWrapperScript = #"""
#!/usr/bin/env bash
# Sich Claude wrapper: inject per-invocation Claude hooks only inside
# Sich-owned terminals, then exec the user's real Claude binary.

is_self_or_shim() {
    candidate="$1"
    [ -n "$candidate" ] || return 1
    [ -e "$candidate" ] && [ "$candidate" -ef "$0" ] && return 0
    case "$candidate" in
        # Legacy pre-rename shim: never treat it as the real binary or the
        # two shims exec each other forever (a stale ~/.ghostling/bin can
        # outlive the rename on PATH).
        */.sich/bin/claude|*/.ghostling/bin/claude) return 0 ;;
    esac
    return 1
}

find_real_claude() {
    old_ifs="$IFS"
    IFS=:
    for d in $PATH; do
        candidate="$d/claude"
        is_self_or_shim "$candidate" && continue
        if [ -x "$candidate" ]; then
            IFS="$old_ifs"
            printf '%s' "$candidate"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

known_command() {
    case "$1" in
        agents|config|doctor|help|install|mcp|migrate-installer|plugin|plugins|setup-token|\
        uninstall|update|upgrade|vim|completion)
            return 0 ;;
    esac
    return 1
}

option_consumes_value() {
    case "$1" in
        --add-dir|--agent|--agents|--allowedTools|--allowed-tools|--append-system-prompt|\
        --betas|--debug|--debug-file|--disallowedTools|--disallowed-tools|--effort|\
        --fallback-model|--file|--from-pr|--input-format|--max-budget-usd|--mcp-config|\
        --model|--output-format|--permission-mode|--plugin-dir|--plugin-marketplace-url|\
        --plugin-url|--resume|-r|--session-id|--setting-sources|--settings|--system-prompt|\
        --system-prompt-file)
            return 0 ;;
    esac
    return 1
}

should_inject() {
    [ "$SICH_CLAUDE_HOOKS_DISABLED" = "1" ] && return 1
    [ -n "$SICH_CARD_ID" ] || return 1
    [ "$#" -eq 0 ] && return 0
    skip_next=0
    for arg in "$@"; do
        if [ "$skip_next" = "1" ]; then
            skip_next=0
            continue
        fi
        case "$arg" in
            --) return 0 ;;
            --help|-h|--version|-v|--bare|--safe-mode|--background|--bg)
                return 1 ;;
            -*)
                case "$arg" in *=*) ;; *) option_consumes_value "$arg" && skip_next=1 ;; esac
                continue ;;
            *)
                known_command "$arg" && return 1
                return 0 ;;
        esac
    done
    return 0
}

REAL_CLAUDE="$(find_real_claude)" || { echo "Error: claude not found in PATH" >&2; exit 127; }

if ! should_inject "$@"; then
    exec "$REAL_CLAUDE" "$@"
fi

    settings='{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"PreToolUse":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":120}]}],"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"Notification":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"PermissionRequest":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":120}]}],"SubagentStart":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"SubagentStop":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"SessionEnd":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}]}}'

exec "$REAL_CLAUDE" --settings "$settings" "$@"
"""#

private let codexWrapperScript = #"""
#!/usr/bin/env bash
# Sich Codex wrapper: inject per-invocation Codex hooks for managed
# Sich terminals, then exec the user's real Codex binary.

is_self_or_shim() {
    candidate="$1"
    [ -n "$candidate" ] || return 1
    [ -e "$candidate" ] && [ "$candidate" -ef "$0" ] && return 0
    case "$candidate" in
        # Legacy pre-rename shim: see the claude wrapper's note.
        */.sich/bin/codex|*/.ghostling/bin/codex) return 0 ;;
    esac
    return 1
}

find_real_codex() {
    old_ifs="$IFS"
    IFS=:
    for d in $PATH; do
        candidate="$d/codex"
        is_self_or_shim "$candidate" && continue
        if [ -x "$candidate" ]; then
            IFS="$old_ifs"
            printf '%s' "$candidate"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

known_subcommand() {
    case "$1" in
        exec|e|resume|review|login|logout|mcp|plugin|mcp-server|app-server|\
        remote-control|app|completion|update|doctor|sandbox|debug|apply|a|\
        archive|delete|unarchive|fork|cloud|exec-server|features|help)
            return 0 ;;
    esac
    return 1
}

session_subcommand() {
    case "$1" in exec|e|resume) return 0 ;; esac
    return 1
}

option_consumes_value() {
    case "$1" in
        -c|--config|-m|--model|-p|--profile|-C|--cd|--remote|-a|--ask-for-approval|\
        -s|--sandbox|--output-last-message|--enable|--disable)
            return 0 ;;
    esac
    return 1
}

should_inject() {
    [ "$CMUX_CODEX_HOOKS_DISABLED" = "1" ] && return 1
    [ "$SICH_CODEX_HOOKS_DISABLED" = "1" ] && return 1
    [ -n "$SICH_CARD_ID" ] || return 1
    [ "$#" -eq 0 ] && return 0
    skip_next=0
    for arg in "$@"; do
        if [ "$skip_next" = "1" ]; then
            skip_next=0
            continue
        fi
        case "$arg" in
            --) return 0 ;;
            --help|-h|-V|--version) return 1 ;;
            -*)
                case "$arg" in *=*) ;; *) option_consumes_value "$arg" && skip_next=1 ;; esac
                continue ;;
            *)
                if known_subcommand "$arg"; then
                    session_subcommand "$arg"
                    return $?
                fi
                return 0 ;;
        esac
    done
    return 0
}

REAL_CODEX="$(find_real_codex)" || { echo "Error: codex not found in PATH" >&2; exit 127; }

if ! should_inject "$@"; then
    exec "$REAL_CODEX" "$@"
fi

export SICH_CODEX_PID=$$
export SICH_AGENT_LAUNCH_EXECUTABLE="$REAL_CODEX"
export SICH_AGENT_LAUNCH_CWD="$PWD"

profile="${SICH_CODEX_PROFILE:-sich-hooks}"
profile_path="${CODEX_HOME:-$HOME/.codex}/$profile.config.toml"
if [ ! -f "$profile_path" ]; then
    exec "$REAL_CODEX" "$@"
fi

exec "$REAL_CODEX" --profile "$profile" --dangerously-bypass-hook-trust "$@"
"""#

private func codexHookScript(event: String) -> String {
    """
    #!/usr/bin/env bash
    # Append one Codex hook event to Sich's observe-only event file.
    file="${SICH_EVENTS_FILE:-$HOME/.sich/events.jsonl}"
    mkdir -p "$(dirname "$file")" 2>/dev/null
    payload=$(mktemp "${TMPDIR:-/tmp}/sich-codex.XXXXXX" 2>/dev/null || mktemp -t sich-codex)
    cat > "$payload" || true

    # Preserve Codex's canonical hook payload—including session_id, cwd and the
    # event-specific fields—and add only Sich's binding metadata. plutil owns
    # JSON escaping here, avoiding a shell re-serializer that previously replaced
    # every ordinary one-line value with an empty string.
    /usr/bin/plutil -replace sich_agent -string codex "$payload" 2>/dev/null || true
    if [ -n "$SICH_CARD_ID" ]; then
        /usr/bin/plutil -replace sich_card_id -string "$SICH_CARD_ID" "$payload" 2>/dev/null || true
    fi
    /usr/bin/plutil -replace sich_pid -string "${SICH_CODEX_PID:-$PPID}" "$payload" 2>/dev/null || true

    # Read and append the complete record with one open/write so concurrent hooks
    # cannot interleave fragments in the shared JSONL file.
    line=$(cat "$payload")
    printf '%s\\n' "$line" >> "$file" 2>/dev/null
    rm -f "$payload"
    echo '{}'
    exit 0
    """
}
