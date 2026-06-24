import CPtySupport
import Foundation

/// A managed terminal session: a child process running in a pty we own, whose
/// output is read **in-process** and fed into a libghostty-vt ``Terminal``.
///
/// This is the keystone Phase 00 / US-004 capability, now in Swift through the
/// vendored xcframework — no AppleScript, no screen-scrape. Every launch passes
/// through ``PoolFirewall`` first, so a managed session can only ever run on the
/// interactive pool.
public final class PTYSession {
    public let pool: Pool
    public let terminal: Terminal
    public private(set) var masterFD: Int32 = -1
    public private(set) var childPID: pid_t = -1

    private let argv: [String]
    private let rows: UInt16
    private let cols: UInt16

    public init(command argv: [String], rows: UInt16 = 24, cols: UInt16 = 80) throws {
        self.pool = try PoolFirewall.classify(argv)  // firewall on the spawn path
        self.argv = argv
        self.rows = rows
        self.cols = cols
        self.terminal = try Terminal(cols: cols, rows: rows)
    }

    /// Spawn the child in a fresh pty. Idempotent guard: throws if already started.
    public func start() throws {
        guard masterFD < 0 else { throw SessionError.alreadyStarted }
        var child: pid_t = 0
        let fd = withCStringArgv(argv) { cargv in
            gl_spawn_in_pty(cargv, rows, cols, &child)
        }
        guard fd >= 0 else { throw SessionError.spawnFailed(errno: errno) }
        masterFD = fd
        childPID = child
    }

    /// Read available output once and feed it to the terminal.
    /// Returns the number of bytes read, or 0 at EOF.
    @discardableResult
    public func pump(bufferSize: Int = 4096) -> Int {
        var buf = [UInt8](repeating: 0, count: bufferSize)
        let n = buf.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, bufferSize) }
        if n > 0 {
            terminal.write(Array(buf[0..<n]))
            return n
        }
        return 0
    }

    /// Drain the child's output to EOF, feeding every byte to the terminal.
    /// Returns the total bytes read. Handles Linux (read==0) and macOS (EIO) EOF.
    @discardableResult
    public func drainToEOF(bufferSize: Int = 4096) -> Int {
        var buf = [UInt8](repeating: 0, count: bufferSize)
        var total = 0
        while true {
            let n = buf.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, bufferSize) }
            if n > 0 {
                terminal.write(Array(buf[0..<n]))
                total += n
            } else if n == 0 {
                break                       // Linux: slave closed
            } else if errno == EINTR {
                continue
            } else {
                break                       // macOS: EIO at slave close, or real error
            }
        }
        return total
    }

    /// Write raw bytes to the child via the pty master (the keystroke path).
    /// Returns the number of bytes written, or -1 on error.
    @discardableResult
    public func send(_ bytes: [UInt8]) -> Int {
        guard masterFD >= 0, !bytes.isEmpty else { return 0 }
        return bytes.withUnsafeBytes { write(masterFD, $0.baseAddress, bytes.count) }
    }

    /// Non-blocking check for child termination, used by ``SessionRegistry`` to
    /// keep lifecycle state honest (a session is never left `running` after the
    /// process dies). Reaps the child once it has exited and clears `childPID`.
    /// Returns `nil` while still running.
    public func pollExit() -> ProcessExit? {
        guard childPID > 0 else { return nil }
        var status: Int32 = 0
        let r = waitpid(childPID, &status, WNOHANG)
        guard r == childPID else { return nil }   // 0 = still running, -1 = already reaped
        childPID = -1
        return ProcessExit(rawStatus: status)
    }

    /// Reap the child and close the master fd. Safe to call once.
    public func finish() {
        if childPID > 0 {
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
            childPID = -1
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    public enum SessionError: Error, Equatable {
        case alreadyStarted
        case spawnFailed(errno: Int32)
    }
}

/// How a child process terminated, decoded from `waitpid`'s raw status.
public struct ProcessExit: Sendable, Equatable {
    /// Exit code if it exited normally; `nil` if it was killed by a signal.
    public let code: Int32?
    /// Terminating signal if it was killed; `nil` if it exited normally.
    public let signal: Int32?

    public init(rawStatus: Int32) {
        if _wStatusIsExited(rawStatus) {
            self.code = _wExitStatus(rawStatus)
            self.signal = nil
        } else {
            self.code = nil
            self.signal = _wTermSignal(rawStatus)
        }
    }

    /// True when the process ended cleanly with exit code 0.
    public var isClean: Bool { code == 0 }
}

// The `W*` status macros are C macros unavailable to Swift; reimplement the
// (stable, POSIX) bit layout so `ProcessExit` can decode `waitpid` status.
private func _wStatusIsExited(_ status: Int32) -> Bool { (status & 0x7F) == 0 }
private func _wExitStatus(_ status: Int32) -> Int32 { (status >> 8) & 0xFF }
private func _wTermSignal(_ status: Int32) -> Int32 { status & 0x7F }

/// Build a NULL-terminated C argv from Swift strings for the duration of `body`.
private func withCStringArgv<R>(_ argv: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cStrings.append(nil)
    defer { cStrings.forEach { free($0) } }
    return cStrings.withUnsafeBufferPointer { body($0.baseAddress!) }
}
