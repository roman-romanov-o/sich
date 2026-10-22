import Foundation

/// The write side of a pty master. The kernel's tty input queue holds about 1KB
/// (`MAX_INPUT`) and the master fd is non-blocking, so one `write()` of a big
/// paste lands only its first chunk — the "my paste came out cropped" defect.
/// Bytes the pty will not take yet wait here, and a background thread feeds
/// them as the child drains: in order, never dropped, and never interleaved
/// with a keystroke typed while the paste is still landing.
///
/// `poll(POLLOUT)` is the wait primitive on purpose: kqueue's `EVFILT_WRITE`
/// reports a pty master as always writable, so a dispatch write source spins
/// instead of waiting for the child to read.
final class PTYInputQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var draining = false
    private var fd: Int32 = -1

    /// Bytes accepted but not yet taken by the pty.
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var count: Int {
        lock.withLock { pending.count }
    }

    func attach(fd: Int32) {
        lock.withLock { self.fd = fd }
    }

    /// Drop the queue; a drain thread in flight exits on its next pass.
    func detach() {
        lock.withLock {
            pending = []
            fd = -1
        }
    }

    /// Append, then write what the pty accepts right now. Whatever is left over
    /// is handed to a drain thread (one at a time — the writer role is exclusive,
    /// which is what keeps the byte order).
    func enqueue(_ bytes: [UInt8]) {
        lock.lock()
        pending += bytes
        if draining {
            lock.unlock()
            return
        }
        draining = true
        let done = writeLocked()
        lock.unlock()
        if !done { Thread.detachNewThread { [self] in drain() } }
    }

    /// Caller holds `lock`. Returns true once the queue is empty — or dropped,
    /// when the fd is gone — releasing the writer role.
    private func writeLocked() -> Bool {
        while !pending.isEmpty, fd >= 0 {
            let n = pending.withUnsafeBytes { write(fd, $0.baseAddress, pending.count) }
            if n > 0 {
                pending.removeFirst(n)
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            } else {
                break                        // child gone: nothing to deliver to
            }
        }
        pending = []
        draining = false
        return true
    }

    private func drain() {
        while true {
            let fd = lock.withLock { self.fd }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let r = poll(&pfd, 1, 200)
            if r < 0, errno == EINTR { continue }
            lock.lock()
            if r > 0, pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { pending = [] }
            let done = writeLocked()
            lock.unlock()
            if done { return }
        }
    }
}
