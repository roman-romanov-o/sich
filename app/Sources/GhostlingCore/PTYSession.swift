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

    /// Optional observer invoked with each chunk of raw child output as it is read,
    /// right after it is fed to the emulator — the seam the app layer sniffs semantic
    /// signals (OSC-7 cwd) off the live stream without re-reading the fd. Set by the
    /// session's app-side owner; nil by default (a plain terminal, no sniffing).
    public var onOutput: (([UInt8]) -> Void)?

    /// Input-side twin of ``onOutput``: invoked with each chunk written to the child
    /// (keystrokes, pastes) right before the pty write. The deterministic seam an
    /// interaction test uses to assert "this real event put these bytes on the wire"
    /// without racing a live child's tty echo. nil by default.
    public var onInput: (([UInt8]) -> Void)?

    private let argv: [String]
    private var rows: UInt16
    private var cols: UInt16

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

    /// Resize the pty (`TIOCSWINSZ` → SIGWINCH to the child's foreground group) AND
    /// the emulator grid, so the child reflows to the visible window instead of
    /// staying at its spawn-time 80×24. No-op when the cell geometry is unchanged,
    /// so the surface can call this on every layout pass without SIGWINCH spam.
    public func resize(rows: UInt16, cols: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) {
        guard rows > 0, cols > 0, rows != self.rows || cols != self.cols else { return }
        self.rows = rows
        self.cols = cols
        if masterFD >= 0 { _ = gl_set_winsize(masterFD, rows, cols) }
        terminal.resize(cols: cols, rows: rows, cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx)
    }

    /// While true, bytes read from the pty are buffered instead of fed to the
    /// emulator, so the on-screen grid stays still under a mouse selection —
    /// selection coordinates are viewport-relative, and live output shifting the
    /// grid beneath them is exactly the "selection is broken" defect. The pty
    /// keeps draining (the child never blocks on a full tty buffer, per the
    /// back-pressure lesson), and semantic sniffers (`onOutput`) still see every
    /// byte live. Clearing the flag flushes the held bytes into the emulator.
    public var holdOutput = false {
        didSet { if !holdOutput { flushHeldOutput() } }
    }

    /// Bytes buffered while ``holdOutput`` is set — the surface watches this to
    /// force-release a selection the user forgot about before the buffer balloons.
    public private(set) var heldByteCount = 0

    private var heldBytes: [UInt8] = []

    private func flushHeldOutput() {
        guard !heldBytes.isEmpty else { return }
        terminal.write(heldBytes)
        heldBytes = []
        heldByteCount = 0
    }

    /// The single ingestion path every read method funnels through: feed a chunk of
    /// child output to the emulator, then notify ``onOutput`` with the same bytes. Also
    /// the deterministic test seam — push bytes as if read from the child, no live fd
    /// required — so a semantic sniffer sees exactly what the terminal renders.
    public func ingest(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if holdOutput {
            heldBytes += bytes
            heldByteCount = heldBytes.count
        } else {
            terminal.write(bytes)
        }
        onOutput?(bytes)
    }

    /// Read available output once and feed it to the terminal.
    /// Returns the number of bytes read, or 0 at EOF.
    @discardableResult
    public func pump(bufferSize: Int = 4096) -> Int {
        var buf = [UInt8](repeating: 0, count: bufferSize)
        let n = buf.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, bufferSize) }
        if n > 0 {
            ingest(Array(buf[0..<n]))
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
                ingest(Array(buf[0..<n]))
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

    /// Put the master fd in non-blocking mode so a poll-driven reader (a run-loop
    /// timer) can drain "whatever is ready" without ever stalling the main thread
    /// when the child has produced nothing yet. Idempotent.
    public func setNonBlocking() {
        guard masterFD >= 0 else { return }
        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
    }

    /// Outcome of one non-blocking drain: real bytes, nothing-ready-yet, or the
    /// child is gone. Distinguishing `idle` from `eof` is the whole point — plain
    /// ``pump()`` returns 0 for both, which a poll loop would misread as EOF.
    public enum PumpResult: Equatable { case data(Int), idle, eof }

    /// Drain everything available right now (non-blocking) into the terminal.
    /// Requires ``setNonBlocking()`` first. `idle` = EAGAIN (child alive, quiet);
    /// `eof` = slave closed (Linux `read==0`, macOS `EIO`) or a real read error.
    public func pumpAvailable(bufferSize: Int = 4096) -> PumpResult {
        var buf = [UInt8](repeating: 0, count: bufferSize)
        var total = 0
        while true {
            let n = buf.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, bufferSize) }
            if n > 0 {
                ingest(Array(buf[0..<n]))
                total += n
            } else if n == 0 {
                return .eof                                  // Linux: slave closed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return total > 0 ? .data(total) : .idle      // nothing more for now
            } else {
                return .eof                                  // macOS EIO at close, etc.
            }
        }
    }

    /// Write raw bytes to the child via the pty master (the keystroke path).
    /// Returns the number of bytes written, or -1 on error.
    @discardableResult
    public func send(_ bytes: [UInt8]) -> Int {
        guard masterFD >= 0, !bytes.isEmpty else { return 0 }
        onInput?(bytes)
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
    ///
    /// The `waitpid` is **blocking** — only correct for a child that exits on its
    /// own (a self-terminating command, or one already SIGKILLed). For a live
    /// interactive `$SHELL -il` that never exits, call ``terminate()`` instead, or
    /// this hangs forever waiting on a process that is still sitting at its prompt.
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

    /// Kill the child (if still running) and tear down — the **non-blocking**
    /// shutdown for a live interactive shell. Without this, quitting the app (or a
    /// test's teardown) leaks the forked `$SHELL` and `finish()`'s blocking
    /// `waitpid` hangs on a shell that is still at its prompt. SIGKILL then a
    /// WNOHANG reap is enough: the master-fd close sends EOF, the kill is the
    /// belt-and-suspenders for a shell ignoring its controlling-tty hangup.
    public func terminate() {
        if childPID > 0 {
            kill(childPID, SIGKILL)
            var status: Int32 = 0
            // A short bounded reap loop — the kill is delivered synchronously, so
            // the child is reaped within a couple of WNOHANG passes; never block.
            for _ in 0..<100 where waitpid(childPID, &status, WNOHANG) == 0 {
                usleep(1000)
            }
            childPID = -1
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    /// Whether a **recorded** child PID still refers to a live process — the
    /// liveness check the restore path (US-003) uses to decide reopen-vs-closed.
    /// This never re-attaches to the PID (the old pty is gone across a restart); it
    /// only probes existence via `kill(pid, 0)`, so it spawns nothing.
    public static func isProcessAlive(pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
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
