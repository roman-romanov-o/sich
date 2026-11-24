import CoreGraphics
import Foundation

/// Tells whether a Claude Code background shell is a long-lived SERVICE — a server
/// listening on a port, or an app with a window — rather than a job the agent is
/// waiting on (CARD-STATUS.md rule 2.3). The command text cannot tell `swift run
/// MyApp` from `swift run my-tool`; the live process tree can.
///
/// Claude Code writes each background shell's output to
/// `/private/tmp/claude-<uid>/<project-slug>/<session-id>/tasks/<task-id>.output`,
/// keyed by the very `id` the hook payload lists in `background_tasks`. The shell
/// holds that file open, so `lsof` on it finds the shell; its descendants are the
/// task's process tree.
public enum BackgroundShellProbe {

    /// Positive opt-in set ONLY by the real executable entry point — never by tests,
    /// so `swift test` never shells out to `lsof`/`ps`.
    /// nonisolated(unsafe): written once at process start, before first use.
    public nonisolated(unsafe) static var spawningEnabled = false

    /// `true` when some process in the shell's tree listens on a TCP port or owns a
    /// window; `false` when its tree does neither (a job); `nil` when the task's
    /// output file or holder can't be found — the task finished, or probing is off.
    public static func isService(_ shell: HookSessionStore.BackgroundShell) -> Bool? {
        guard spawningEnabled, let output = outputFile(of: shell) else { return nil }
        let holders = pids(run("/usr/sbin/lsof", ["-t", output.path]))
        guard !holders.isEmpty else { return nil }
        let tree = descendants(of: holders)
        return listens(tree) || ownsWindow(tree)
    }

    /// The task's output file, searched across project slugs (the slug is derived
    /// from the launch cwd, which the session may since have left).
    private static func outputFile(of shell: HookSessionStore.BackgroundShell) -> URL? {
        let root = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())")
        let projects = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return projects
            .map { $0.appendingPathComponent("\(shell.sessionID)/tasks/\(shell.taskID).output") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func descendants(of roots: Set<Int32>) -> Set<Int32> {
        var children: [Int32: [Int32]] = [:]
        for line in run("/bin/ps", ["-axo", "pid=,ppid="]).split(separator: "\n") {
            let fields = line.split(separator: " ").compactMap { Int32($0) }
            if fields.count == 2 { children[fields[1], default: []].append(fields[0]) }
        }
        var tree: Set<Int32> = []
        var stack = Array(roots)
        while let pid = stack.popLast() {
            if tree.insert(pid).inserted { stack += children[pid] ?? [] }
        }
        return tree
    }

    private static func listens(_ tree: Set<Int32>) -> Bool {
        let list = tree.map(String.init).joined(separator: ",")
        return !pids(run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-t", "-p", list])).isEmpty
    }

    /// Window owner pids are readable without Screen Recording permission (only
    /// window titles need it).
    private static func ownsWindow(_ tree: Set<Int32>) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { window in
            (window[kCGWindowOwnerPID as String] as? Int32).map(tree.contains) ?? false
        }
    }

    private static func pids(_ output: String) -> Set<Int32> {
        Set(output.split(separator: "\n").compactMap { Int32($0) })
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
