import CryptoKit
import Foundation

/// One whole line read off a remote host's event log, carrying the host it came
/// from (US-003 AC-2).
///
/// Provenance is STRUCTURAL, not parsed: a hook payload has no hostname field, so
/// "which machine wrote this" exists for exactly one instant — the channel we
/// opened to a known host — and is unrecoverable afterwards. Binding the host to
/// the bytes at read time makes a hostless relayed line unrepresentable.
public struct RemoteEventLine: Sendable, Equatable {
    /// The host the relay dialled. Never read out of the payload.
    public let host: String
    /// The raw line, byte-for-byte as the far side wrote it.
    public let line: Data

    public init(host: String, line: Data) {
        self.host = host
        self.line = line
    }

    /// The wire key the stamp lands under: the existing hook line PLUS `sich_host`.
    public static let hostKey = "sich_host"

    /// Parse this line and stamp it — the ingestion step, run BEFORE any normalizer
    /// sees the payload. Returns `nil` for a non-JSON line (skipped, not fatal).
    ///
    /// The stamp OVERWRITES any `sich_host` the far side supplied: a value that
    /// travelled over the wire is a claim, and the only fact here is the host this
    /// channel was opened to.
    public func stampedPayload() -> [String: Any]? {
        guard var payload = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return nil }
        payload[Self.hostKey] = host
        return payload
    }
}

/// What the relay knows about one host's link.
///
/// `connecting` covers "the child is up and has said nothing yet" — which is also
/// the state of a host whose event log does not exist yet. Silence is not a dead
/// link, so that case must never read `unreachable` (US-003 edge case 3).
public enum RemoteRelayHealth: String, Sendable, Equatable {
    case connecting
    case streaming
    case unreachable
}

/// A running relay child. Cancelling is idempotent.
public protocol RemoteLineStream: AnyObject, Sendable {
    func cancel()
}

/// The transport seam. Tests inject a local stand-in so no test dials a host.
///
/// Lines are delivered in the batches they were read in — one hop per chunk, not
/// per line, because the consumer side of this hops to the main actor.
public protocol RemoteLineTransport: Sendable {
    /// Launch `argv`; `onLines` fires per read chunk, `onExit` once with the child's
    /// status. Returns `nil` when the child could not be launched at all.
    func start(
        argv: [String],
        onLines: @escaping @Sendable ([Data]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> RemoteLineStream?
}

/// Follows one remote host's `~/.sich/events.jsonl` over `ssh … tail -n 200 -F`
/// and hands the laptop host-stamped lines, in memory (DD-001).
///
/// Three properties this exists to hold:
///  * **no byte cursor.** The forwarder rotates the log with `mv -f` at 5 MiB, so a
///    remembered offset points into a file that no longer exists (or into the middle
///    of a smaller one). `-F` follows the name; we remember content, never a position.
///  * **bounded replay.** A reconnect re-runs `tail -n 200`, so at most 200 lines of
///    history come back, and the content dedup drops the ones already ingested.
///  * **observe-only.** This opens an outbound ssh and reads its stdout. Nothing is
///    written to the far side, nothing is written to the local event file, no port is
///    bound and no reply is ever sent.
public final class RemoteEventRelay: @unchecked Sendable {

    /// ssh's own failure status. ssh returns the REMOTE command's status otherwise,
    /// which is how "the host answered but the log is missing" stays distinguishable
    /// from "the link died" (keepalive timeout → 255).
    static let sshFailureExit: Int32 = 255

    /// How many line digests are remembered. Comfortably over the 200-line replay
    /// window, and bounded so a long-lived relay cannot grow without limit (US-008).
    public static let dedupCapacity = 512

    /// The host as stamped onto every line — the spec's host, validated through the
    /// destination chokepoint at init.
    public let host: String

    private let argv: [String]
    private let transport: RemoteLineTransport
    private let reconnectDelay: TimeInterval
    private let sink: @Sendable ([RemoteEventLine]) -> Void

    private let lock = NSLock()
    private var stream: RemoteLineStream?
    private var stopped = false
    private var seen: DedupWindow
    private var currentHealth: RemoteRelayHealth = .connecting

    /// Throws when the spec cannot produce a legal ssh destination — the same
    /// chokepoint every other remote channel goes through (DD-004 / AC-5).
    public init(
        spec: RemoteTmuxSpec,
        transport: RemoteLineTransport,
        reconnectDelay: TimeInterval = 5,
        sink: @escaping @Sendable ([RemoteEventLine]) -> Void
    ) throws {
        self.argv = try RemoteTmuxCommand.relayArgv(for: spec)
        self.host = try RemoteTmuxCommand.hostToken(for: spec)
        self.transport = transport
        self.reconnectDelay = reconnectDelay
        self.sink = sink
        self.seen = DedupWindow(capacity: Self.dedupCapacity)
    }

    public var health: RemoteRelayHealth {
        lock.lock()
        defer { lock.unlock() }
        return currentHealth
    }

    /// Digests currently held — the memory bound made observable.
    // periphery:ignore - test-only entry (scan runs with exclude_tests)
    var dedupWindowCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }

    public func start() {
        lock.lock()
        stopped = false
        lock.unlock()
        launch()
    }

    /// Tear the child down and suppress the reconnect its exit would otherwise cause.
    public func stop() {
        lock.lock()
        stopped = true
        let running = stream
        stream = nil
        lock.unlock()
        running?.cancel()
    }

    // MARK: - Internals

    private func launch() {
        let started = transport.start(
            argv: argv,
            onLines: { [weak self] lines in self?.receive(lines) },
            onExit: { [weak self] code in self?.childExited(code) }
        )
        lock.lock()
        // A refusal is LOCAL (spawning disabled, fork failed): retrying cannot fix it,
        // so the relay goes quiet instead of spinning a reconnect loop forever.
        if started == nil { currentHealth = .unreachable }
        if stopped {
            lock.unlock()
            started?.cancel()
            return
        }
        stream = started
        lock.unlock()
    }

    /// Bytes arrived, so the link is alive — that is true even when every line in the
    /// chunk is a replay the dedup drops.
    private func receive(_ lines: [Data]) {
        lock.lock()
        currentHealth = .streaming
        let fresh = lines.filter { seen.admit($0) }
        lock.unlock()
        guard !fresh.isEmpty else { return }
        sink(fresh.map { RemoteEventLine(host: host, line: $0) })
    }

    /// The child died. Only ssh's own 255 means the LINK is down (a refused dial or a
    /// keepalive timeout at ServerAliveInterval=15 × ServerAliveCountMax=3). Any other
    /// status came from the remote command, which means the host answered.
    private func childExited(_ code: Int32) {
        lock.lock()
        stream = nil
        guard !stopped else { return lock.unlock() }
        if code == Self.sshFailureExit { currentHealth = .unreachable }
        let delay = reconnectDelay
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.launch()
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

/// Content-based dedup over a bounded FIFO of SHA-256 digests.
///
/// Digests and not lines: a hook line can carry a large payload, and remembering 512
/// of those would cost more than the board. A digest costs 32 bytes and answers the
/// only question asked — "have I already ingested exactly these bytes".
struct DedupWindow {
    private var digests: Set<Data> = []
    private var order: [Data] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { order.count }

    /// True when the line is new (and now remembered); false for a replay.
    mutating func admit(_ line: Data) -> Bool {
        let digest = Data(SHA256.hash(data: line))
        guard digests.insert(digest).inserted else { return false }
        order.append(digest)
        if order.count > capacity { digests.remove(order.removeFirst()) }
        return true
    }
}
