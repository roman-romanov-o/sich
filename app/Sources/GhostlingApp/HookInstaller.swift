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
        let path = repoRoot.appendingPathComponent(".claude/settings.json")
        var cfg = readConfig(path)
        var hooks = cfg["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            guard !alreadyForwarding(groups) else { continue }
            hooks[event] = appendForward(into: groups)
            changed = true
        }
        guard changed else { return false }
        cfg["hooks"] = hooks
        return writeConfig(cfg, to: path)
    }

    /// True if any group in this event already runs the forwarder — the idempotency
    /// guard that makes re-running install a no-op.
    private static func alreadyForwarding(_ groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? [])
                .contains { $0["command"] as? String == forward }
        }
    }

    /// Append the forwarder, reusing an existing `matcher: ""` group (e.g.
    /// SessionStart's welcome) if present, else creating one — so welcome.sh and the
    /// forwarder share a group exactly as the shell enabler produces.
    private static func appendForward(into groups: [[String: Any]]) -> [[String: Any]] {
        var groups = groups
        let entry: [String: Any] = ["type": "command", "command": forward]
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
