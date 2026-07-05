import Foundation

/// A kernel FS-object watch on a single file (DD-002): the PRIMARY, event-driven
/// trigger so a hook append reaches the board sub-250ms without the 3s busy poll.
/// A `.write` fires `onChange`; a `.rename`/`.delete`/`.revoke` (rotation) re-arms on
/// the replacement file so delivery doesn't silently stop. Watcher-safe: it opens the
/// file read-only (`O_EVTONLY`) and never writes it.
///
/// The source runs on `.main`, matching `TerminalSurface`'s read loop: production
/// drains the main queue under `NSApp.run()`, and the demoted low-frequency backstop
/// `Timer` covers the spun-loop / AppKit-nesting gaps where a `.main` source can be
/// sluggish or a re-arm is missed.
@MainActor
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    /// True once armed on a live fd. The poller's backstop re-arms when this is false
    /// (e.g. the event file did not exist yet at launch).
    var isArmed: Bool { source != nil }

    /// Arm (or re-arm) the watch on `path`. Idempotent: cancels any prior source first.
    /// A missing file is not fatal — it leaves the watch unarmed for the backstop to
    /// retry once the forwarder creates the file.
    func start() {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .revoke],
            queue: .main
        )
        source = src
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let mask = self.source?.data else { return }
                self.handle(mask)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Rotation (`rename`/`delete`/`revoke`) points `path` at a new inode: re-arm on
    /// the replacement, then still drain — the reader is inode-reset-safe
    /// (`HookEventTail.resolveStart`). A plain `.write` just drains.
    private func handle(_ mask: DispatchSource.FileSystemEvent) {
        let rotated = !mask.isDisjoint(with: [.rename, .delete, .revoke])
        if rotated { start() }
        onChange()
    }

    /// Test seam (DD-002 anti-flake, TC-INT-002): fire the change handler as if the
    /// kernel source saw a `.write`, so a test proves "FS event → read"
    /// deterministically — never a real FS race or wall-clock latency (mirrors the
    /// GridTextTests fromPTY PTY-EOF flake precedent).
    func fireForTesting() { onChange() }
}
