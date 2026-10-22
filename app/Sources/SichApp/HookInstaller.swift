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
    /// Cursor ships the CLI as both `agent` and `cursor-agent`; one wrapper body
    /// serves both names so a human typing either inside a card is still observed.
    static let cursorShimNames = ["agent", "cursor-agent"]
    static let cursorHookScriptName = "sich-cursor.sh"
    /// Google's Antigravity CLI ships as one binary, `agy`.
    static let antigravityShimName = "agy"
    static let antigravityHookScriptName = "sich-antigravity.sh"
    /// The named entry Sich owns inside `~/.gemini/config/hooks.json`.
    static let antigravityHookEntryName = "sich"
    /// Lifecycle events the board cares about: appear → run → wait (Stop = turn end) →
    /// done (SessionEnd = the session actually closed — the only real Done).
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "Notification", "SubagentStart", "SubagentStop",
        "PreCompact", "Stop", "SessionEnd",
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

    /// Install the forwarder into a named profile's config dir (`$CLAUDE_CONFIG_DIR/settings.json`).
    @discardableResult
    static func installProfileHooks(configDir: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let script = home.appendingPathComponent(".sich/sich-forward.sh")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        guard (try? forwarderScript.write(to: script, atomically: true, encoding: .utf8)) != nil
        else { return false }
        return install(settings: configDir.appendingPathComponent("settings.json"),
                       command: "bash \(script.path)")
    }

    /// Provision hooks and config scaffolding for a registered agent account (local).
    @discardableResult
    static func provisionAccount(_ account: AgentAccountProfile) -> Bool {
        let root = URL(fileURLWithPath: account.resolvedConfigRoot, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        switch account.agent {
        case .claude:
            return installProfileHooks(configDir: root)
        case .codex:
            _ = installCodexShim()
            let profile = account.codexProfileName ?? codexProfileName
            let profileURL = root.appendingPathComponent("\(profile).config.toml")
            let hookDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(codexHookDirName, isDirectory: true)
            return (try? codexProfile(hookDir: hookDir).write(
                to: profileURL, atomically: true, encoding: .utf8)) != nil
        case .cursor:
            _ = installCursorHooks()
            return installCursorAccountHooks(configDir: root)
        case .gemini, .antigravity:
            return false
        }
    }

    /// Cursor hooks for an isolated `CURSOR_CONFIG_DIR` account root.
    @discardableResult
    static func installCursorAccountHooks(configDir: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hookScript = home.appendingPathComponent("\(codexHookDirName)/\(cursorHookScriptName)")
        _ = installCursorHooks()
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let config = configDir.appendingPathComponent("hooks.json")
        guard let patched = cursorPatched(readConfig(config), command: hookScript.path) else {
            return FileManager.default.fileExists(atPath: config.path)
        }
        return writeConfig(patched, to: config)
    }

    /// Install account-scoped hooks on a remote host (Claude settings, Codex profile, Cursor hooks).
    @discardableResult
    static func installRemoteAccount(
        spec: RemoteTmuxSpec, account: AgentAccountProfile, runner: RemoteCommandRunner
    ) -> Bool {
        guard push(Data(forwarderScript.utf8), to: .forwarder, spec: spec, runner: runner)
        else { return false }
        switch account.agent {
        case .claude:
            guard let relative = account.settingsRelativePath else { return false }
            return patchRemoteSettings(relative: relative, spec: spec, runner: runner)
        case .codex:
            guard let relative = account.settingsRelativePath else { return false }
            let hookDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(codexHookDirName, isDirectory: true)
            let body = Data(codexProfile(hookDir: hookDir).utf8)
            return push(body, relativePath: relative, mode: "644", spec: spec, runner: runner)
        case .cursor:
            guard let relative = account.settingsRelativePath else { return false }
            let hookScript = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("\(codexHookDirName)/\(cursorHookScriptName)")
            guard let patched = cursorPatched([:], command: hookScript.path),
                  let data = configData(patched)
            else { return false }
            return push(data, relativePath: relative, mode: "644", spec: spec, runner: runner)
        case .gemini, .antigravity:
            return false
        }
    }

    private static func patchRemoteSettings(
        relative: String, spec: RemoteTmuxSpec, runner: RemoteCommandRunner
    ) -> Bool {
        guard case .bytes(let raw) = readRemote(relative: relative, spec: spec, runner: runner)
        else { return false }
        guard let patched = patched(config(from: raw), command: remoteForward),
              let data = configData(patched)
        else { return true }
        return push(data, relativePath: relative, mode: "644", spec: spec, runner: runner)
    }

    private static func readRemote(
        relative: String, spec: RemoteTmuxSpec, runner: RemoteCommandRunner
    ) -> RemoteRead {
        guard let argv = try? RemoteTmuxCommand.probeArgv(for: spec, relativePath: relative),
              let result = runner.run(argv: argv, input: nil), result.succeeded
        else { return .failed }
        return .bytes(result.standardOutput)
    }

    private static func push(
        _ bytes: Data, relativePath: String, mode: String,
        spec: RemoteTmuxSpec, runner: RemoteCommandRunner
    ) -> Bool {
        guard let argv = try? RemoteTmuxCommand.installArgv(
            for: spec, relativePath: relativePath, mode: mode),
              let result = runner.run(argv: argv, input: bytes)
        else { return false }
        return result.succeeded
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

    /// Cursor has no per-invocation settings flag (unlike `claude --settings` and
    /// `codex --profile`), so observation is wired at the USER level: one hook script
    /// merged into `~/.cursor/hooks.json` for every lifecycle event the board reads.
    /// The script itself is scoped — it emits nothing unless `SICH_CARD_ID` is in its
    /// environment — so Cursor runs outside a Sich terminal stay silent. The shim in
    /// `~/.sich/bin` only pins the launch cwd/pid for the hook lines and execs the
    /// real binary.
    @discardableResult
    static func installCursorHooks(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let binDir = home.appendingPathComponent(codexBinDirName, isDirectory: true)
        let hookDir = home.appendingPathComponent(codexHookDirName, isDirectory: true)
        let script = hookDir.appendingPathComponent(cursorHookScriptName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)
            for name in cursorShimNames {
                let shim = binDir.appendingPathComponent(name, isDirectory: false)
                try cursorWrapperScript.write(to: shim, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            }
            try cursorHookScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return false
        }
        let config = home.appendingPathComponent(".cursor/hooks.json")
        guard let patched = cursorPatched(readConfig(config), command: script.path) else { return true }
        return writeConfig(patched, to: config)
    }

    /// Merge the Cursor hook script into every board event of a `hooks.json`
    /// (`{"version":1,"hooks":{"<event>":[{"command":...}]}}`), preserving whatever
    /// hooks the user already has. `nil` when it is already fully wired.
    static func cursorPatched(_ config: [String: Any], command: String) -> [String: Any]? {
        var cfg = config
        var hooks = cfg["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in cursorEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            guard !entries.contains(where: { $0["command"] as? String == command }) else { continue }
            entries.append(["command": command, "timeout": 10])
            hooks[event] = entries
            changed = true
        }
        guard changed else { return nil }
        if cfg["version"] == nil { cfg["version"] = 1 }
        cfg["hooks"] = hooks
        return cfg
    }

    /// Antigravity is wired like Cursor — at the USER level, one script merged into
    /// `~/.gemini/config/hooks.json` under a named entry — with two twists: its payload
    /// carries NO event name, so the installed command names the event
    /// (`sich-antigravity.sh Stop`) and the script stamps `hook_event_name`; and its
    /// `PreToolUse` hook MUST answer a permission decision, so the board hooks only the
    /// no-output events (`PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`).
    /// `agy` runs hooks with the config directory as cwd, hence the absolute path.
    @discardableResult
    static func installAntigravityHooks(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let binDir = home.appendingPathComponent(codexBinDirName, isDirectory: true)
        let hookDir = home.appendingPathComponent(codexHookDirName, isDirectory: true)
        let script = hookDir.appendingPathComponent(antigravityHookScriptName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)
            let shim = binDir.appendingPathComponent(antigravityShimName, isDirectory: false)
            try antigravityWrapperScript.write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            try antigravityHookScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return false
        }
        let configDir = home.appendingPathComponent(".gemini/config", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let config = configDir.appendingPathComponent("hooks.json", isDirectory: false)
        guard let patched = antigravityPatched(readConfig(config), script: script.path) else { return true }
        return writeConfig(patched, to: config)
    }

    /// Build Sich's named entry for an Antigravity `hooks.json` and merge it in,
    /// leaving every other named entry untouched. `nil` when it is already current.
    static func antigravityPatched(_ config: [String: Any], script: String) -> [String: Any]? {
        let entry = antigravityHookEntry(script: script)
        let existing = config[antigravityHookEntryName] as? [String: Any]
        guard existing == nil || !NSDictionary(dictionary: existing!).isEqual(to: entry) else { return nil }
        var cfg = config
        cfg[antigravityHookEntryName] = entry
        return cfg
    }

    static func antigravityHookEntry(script: String) -> [String: Any] {
        func handler(_ event: String) -> [String: Any] {
            ["type": "command", "command": "\(shellQuoted(script)) \(event)", "timeout": 10]
        }
        return [
            "enabled": true,
            "PostToolUse": [["matcher": "*", "hooks": [handler("PostToolUse")]]],
            "PreInvocation": [handler("PreInvocation")],
            "PostInvocation": [handler("PostInvocation")],
            "Stop": [handler("Stop")],
        ]
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

size=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
if [ "${size:-0}" -gt "$max_bytes" ] 2>/dev/null; then
    mv -f "$file" "$file.1" 2>/dev/null
fi
exit 0
"""#

/// Cursor's lifecycle events, in its camelCase vocabulary — `HookNormalizer` maps
/// them onto the same signal kinds as the Claude/Codex names. `postToolUseFailure`
/// stands in for the permission-denied path; Cursor has no permission-request hook.
private let cursorEvents = [
    "sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse",
    "postToolUseFailure", "subagentStart", "subagentStop", "preCompact",
    "stop", "sessionEnd",
]

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

    settings='{"theme":"\#(ClaudeTheme.settingsRef)","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"PreToolUse":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":120}]}],"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"Notification":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"PermissionRequest":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":120}]}],"SubagentStart":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"SubagentStop":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}],"SessionEnd":[{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOME"'/.sich/sich-forward.sh","timeout":10}]}]}}'

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

private let cursorWrapperScript = #"""
#!/usr/bin/env bash
# Sich Cursor wrapper: pin the launch facts the Sich hook script stamps on every
# Cursor hook line, then exec the user's real Cursor CLI (`agent`/`cursor-agent`).
# Observation itself lives in ~/.cursor/hooks.json; this wrapper never edits it.

name="$(basename "$0")"

is_self_or_shim() {
    candidate="$1"
    [ -n "$candidate" ] || return 1
    [ -e "$candidate" ] && [ "$candidate" -ef "$0" ] && return 0
    case "$candidate" in
        */.sich/bin/agent|*/.sich/bin/cursor-agent) return 0 ;;
    esac
    return 1
}

find_real_agent() {
    old_ifs="$IFS"
    IFS=:
    for d in $PATH; do
        candidate="$d/$name"
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

REAL_AGENT="$(find_real_agent)" || { echo "Error: $name not found in PATH" >&2; exit 127; }

if [ -n "$SICH_CARD_ID" ]; then
    export SICH_CURSOR_PID=$$
    export SICH_AGENT_LAUNCH_EXECUTABLE="$REAL_AGENT"
    export SICH_AGENT_LAUNCH_CWD="$PWD"
fi

exec "$REAL_AGENT" "$@"
"""#

/// One script for every Cursor event: the event name already rides the payload's
/// `hook_event_name`. Scoped by `SICH_CARD_ID` — outside a Sich terminal it answers
/// `{}` without touching the event file.
private let cursorHookScript = #"""
#!/usr/bin/env bash
# Append one Cursor hook event to Sich's observe-only event file.
if [ -z "$SICH_CARD_ID" ]; then
    cat > /dev/null
    echo '{}'
    exit 0
fi
file="${SICH_EVENTS_FILE:-$HOME/.sich/events.jsonl}"
mkdir -p "$(dirname "$file")" 2>/dev/null
payload=$(mktemp "${TMPDIR:-/tmp}/sich-cursor.XXXXXX" 2>/dev/null || mktemp -t sich-cursor)
cat > "$payload" || true

# Keep Cursor's canonical payload (conversation_id, workspace_roots, the event
# fields) and add only Sich's binding metadata; plutil owns the JSON escaping.
/usr/bin/plutil -replace sich_agent -string cursor "$payload" 2>/dev/null || true
/usr/bin/plutil -replace sich_card_id -string "$SICH_CARD_ID" "$payload" 2>/dev/null || true
/usr/bin/plutil -replace sich_pid -string "${SICH_CURSOR_PID:-$PPID}" "$payload" 2>/dev/null || true

line=$(cat "$payload")
printf '%s
' "$line" >> "$file" 2>/dev/null
rm -f "$payload"
echo '{}'
exit 0
"""#

private let antigravityWrapperScript = #"""
#!/usr/bin/env bash
# Sich Antigravity wrapper: pin the launch facts the Sich hook script stamps on
# every Antigravity hook line, then exec the user's real `agy`. Observation
# itself lives in ~/.gemini/config/hooks.json; this wrapper never edits it.

name="$(basename "$0")"

is_self_or_shim() {
    candidate="$1"
    [ -n "$candidate" ] || return 1
    [ -e "$candidate" ] && [ "$candidate" -ef "$0" ] && return 0
    case "$candidate" in
        */.sich/bin/agy) return 0 ;;
    esac
    return 1
}

find_real_agent() {
    old_ifs="$IFS"
    IFS=:
    for d in $PATH "$HOME/.local/bin"; do
        candidate="$d/$name"
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

REAL_AGENT="$(find_real_agent)" || { echo "Error: $name not found in PATH (install: curl -fsSL https://antigravity.google/cli/install.sh | bash)" >&2; exit 127; }

if [ -n "$SICH_CARD_ID" ]; then
    export SICH_ANTIGRAVITY_PID=$$
    export SICH_AGENT_LAUNCH_EXECUTABLE="$REAL_AGENT"
    export SICH_AGENT_LAUNCH_CWD="$PWD"
fi

exec "$REAL_AGENT" "$@"
"""#

/// One script for every Antigravity event, the event name passed as `$1` because
/// the payload carries none. Scoped by `SICH_CARD_ID` — outside a Sich terminal it
/// answers `{}` without touching the event file.
private let antigravityHookScript = #"""
#!/usr/bin/env bash
# Append one Antigravity hook event to Sich's observe-only event file.
event="${1:-unknown}"
if [ -z "$SICH_CARD_ID" ]; then
    cat > /dev/null
    echo '{}'
    exit 0
fi
file="${SICH_EVENTS_FILE:-$HOME/.sich/events.jsonl}"
mkdir -p "$(dirname "$file")" 2>/dev/null
payload=$(mktemp "${TMPDIR:-/tmp}/sich-antigravity.XXXXXX" 2>/dev/null || mktemp -t sich-antigravity)
cat > "$payload" || true
[ -s "$payload" ] || printf '{}' > "$payload"

# Keep Antigravity's canonical payload (conversationId, workspacePaths, tool
# fields) and add the event name plus Sich's binding metadata.
/usr/bin/plutil -replace hook_event_name -string "$event" "$payload" 2>/dev/null || true
/usr/bin/plutil -replace sich_agent -string antigravity "$payload" 2>/dev/null || true
/usr/bin/plutil -replace sich_card_id -string "$SICH_CARD_ID" "$payload" 2>/dev/null || true
/usr/bin/plutil -replace sich_pid -string "${SICH_ANTIGRAVITY_PID:-$PPID}" "$payload" 2>/dev/null || true

line=$(cat "$payload")
printf '%s\n' "$line" >> "$file" 2>/dev/null
rm -f "$payload"
echo '{}'
exit 0
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
