import Darwin
import Foundation

/// Runtime assertions of the Phase-03 single-binary end state (US-001): the running
/// app spawns no Python child and binds no localhost sidecar port. These back the
/// cutover E2E checks (TC-E2E-301/302) and the headless cutover tests — they observe
/// the live process, they never spawn anything themselves.
///
/// Watcher-not-spawner: `hasPythonChild` only INSPECTS the process tree (a read-only
/// `ps` query); `portInUse` only attempts a TCP connect. Neither launches an agent.
public enum CutoverGuard {

    /// The localhost port the retired Python sidecar listened on. The ONLY place this
    /// literal survives — every guard names this constant, so the grep guard can prove
    /// no other code couples to the old wire. After the cutover this port stays free.
    public static let sidecarPort: UInt16 = 8787

    /// True if any direct child of this process is a `python`/`python3` interpreter.
    /// Reads the live process tree via `ps` (parent-PID column) — no spawn of our own
    /// beyond the read-only query. After the cutover this must be **false** on launch.
    public static func hasPythonChild(of pid: pid_t = getpid()) -> Bool {
        childCommands(of: pid).contains { isPython($0) }
    }

    /// The command name of every direct child of `pid`, from `ps -o ppid=,comm=`.
    /// An unreadable / failed `ps` yields no children (treated as "no python child").
    static func childCommands(of pid: pid_t) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "ppid=,comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return parseChildCommands(String(decoding: data, as: UTF8.self), parent: pid)
    }

    /// Parse `ps -o ppid=,comm=` rows, returning the command of each row whose parent
    /// pid is `parent`. Split here (pure) so a test can drive it without a live `ps`.
    static func parseChildCommands(_ output: String, parent: pid_t) -> [String] {
        output.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, pid_t(fields[0]) == parent else { return nil }
            return fields[1].trimmingCharacters(in: .whitespaces)
        }
    }

    /// True if `comm` names a Python interpreter (`python`, `python3`, `python3.12`, …).
    static func isPython(_ comm: String) -> Bool {
        let base = (comm as NSString).lastPathComponent.lowercased()
        return base == "python" || base.hasPrefix("python")
    }

    /// True if something is already listening on `127.0.0.1:port` (a TCP connect
    /// succeeds). After the cutover `sidecarPort` must be **free** — the app neither
    /// spawns a listener nor depends on one.
    public static func portInUse(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
