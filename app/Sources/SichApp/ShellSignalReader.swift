import Foundation
import SichCore

// The bytes that bracket an OSC-7 report on the wire: `ESC ]` opens it, and it ends
// on either a BEL or an ST (`ESC \`). Kept as named constants so the scanner reads.
private let esc: UInt8 = 0x1B
private let oscOpen: UInt8 = 0x5D       // ']'
private let bel: UInt8 = 0x07
private let stFinal: UInt8 = 0x5C       // '\' — the second byte of ST (ESC \)

/// Sniffs OSC-7 cwd reports off a live terminal byte stream, tolerating a sequence
/// that splits across arbitrary read chunks (the real loop chunks output any which
/// way). Single responsibility: bytes in → reported cwd out, delegating the actual
/// path extraction to the pure ``ShellIntegration/reportedCwd(fromOSC:)`` parser.
///
/// Bounded: an in-progress OSC is buffered only from `ESC ]` to its terminator, capped
/// so a truncated or garbage escape can never grow memory without bound — a runaway
/// sequence is abandoned and scanning resets.
final class OSC7CwdReader {
    private let onCwd: (String) -> Void
    private var body: [UInt8] = []
    private var state: Scan = .idle
    private static let cap = 4096

    private enum Scan { case idle, sawEsc, inOSC, oscSawEsc }

    init(onCwd: @escaping (String) -> Void) { self.onCwd = onCwd }

    /// Feed one chunk of child output; emits the cwd for each complete OSC-7 seen.
    func feed(_ bytes: [UInt8]) { for b in bytes { step(b) } }

    private func step(_ b: UInt8) {
        switch state {
        case .idle:
            if b == esc { state = .sawEsc }
        case .sawEsc:
            if b == oscOpen { state = .inOSC; body.removeAll(keepingCapacity: true) }
            else { state = (b == esc) ? .sawEsc : .idle }
        case .inOSC:
            if b == bel { finish() }              // BEL terminator
            else if b == esc { state = .oscSawEsc }
            else { append(b) }
        case .oscSawEsc:
            if b == stFinal { finish() }          // ESC \ = ST terminator
            else if b == esc { break }            // consecutive ESC; keep waiting
            else { append(esc); append(b); state = .inOSC }
        }
    }

    /// Buffer one OSC-body byte, abandoning the sequence if it outgrows the cap.
    private func append(_ b: UInt8) {
        guard body.count < Self.cap else {
            body.removeAll(keepingCapacity: true)
            state = .idle
            return
        }
        body.append(b)
    }

    /// Reconstruct the full envelope and hand it to the pure parser; a non-OSC-7
    /// escape (title set, prompt mark) parses to nil and is silently ignored.
    private func finish() {
        let envelope = [esc, oscOpen] + body + [esc, stFinal]
        if let cwd = ShellIntegration.reportedCwd(fromOSC: String(decoding: envelope, as: UTF8.self)) {
            onCwd(cwd)
        }
        body.removeAll(keepingCapacity: true)
        state = .idle
    }
}

/// Wires a managed session's live PTY output to its REPORTED cwd (US-004): as bytes
/// arrive on the real read loop, sniff OSC-7 and update the session's cwd
/// semantically, so a live `cd` in the terminal is reflected without a process scan.
///
/// The scanner is retained by the pty's `onOutput` closure; the session is captured
/// weakly, so this adds no retain cycle (session → pty → onOutput → reader → weak
/// session). This is the callsite that makes ``ShellIntegration/reportedCwd(fromOSC:)``
/// reachable from the live stream instead of a dead parser.
enum ShellSignalBridge {
    static func attachCwdReporting(to session: Session) {
        let reader = OSC7CwdReader { [weak session] cwd in session?.reportCwd(cwd) }
        session.pty.onOutput = { reader.feed($0) }
    }
}
