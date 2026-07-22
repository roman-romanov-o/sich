import Foundation

/// The user-facing disposition of a session's lifecycle, derived from
/// ``SessionState``. This is the presentation-layer classification the window
/// title (Phase 01) and the board card (Phase 03) both render — kept window-free
/// and pure so it is unit-testable without AppKit (mirroring `KeyEncoder`).
///
/// The crucial distinction it draws, which the *registry* deliberately does not
/// (its `.crashed` lumps any non-zero outcome together): a clean `WIFEXITED`
/// process — even with a non-zero code — is an **exit**, never a **crash**. Only
/// a terminating *signal* (`WIFSIGNALED`) is a crash. TC-E2E-104 defines a crash
/// as an abrupt kill (a signal), not a non-zero exit; US-001 Edge Case 2 requires
/// a deliberate logout to "show the exit cleanly".
public enum SessionDisposition: Sendable, Equatable {
    case starting
    case running
    /// Exited normally with the carried code (`0` for a clean logout, non-zero
    /// for the exit status of the shell's last command — e.g. Ctrl-C then Ctrl-D).
    case exited(code: Int32)
    /// Killed by a terminating signal — the only true "crash" (TC-E2E-104).
    case crashed(signal: Int32)

    /// Classify a ``SessionState`` for presentation. The `.crashed(ProcessExit)`
    /// registry state is split here by inspecting the payload the registry already
    /// carries: a signal death stays a crash; a non-zero *exit* becomes an exit.
    public init(state: SessionState) {
        switch state {
        case .starting:
            self = .starting
        case .running:
            self = .running
        case .exited:
            self = .exited(code: 0)
        case .crashed(let exit):
            self = Self.fromTerminated(exit)
        }
    }

    private static func fromTerminated(_ exit: ProcessExit) -> SessionDisposition {
        if let signal = exit.signal {
            return .crashed(signal: signal)   // WIFSIGNALED: an abrupt kill
        }
        return .exited(code: exit.code ?? 0)  // WIFEXITED, any code: a clean exit
    }

    /// True when the session has reached a terminal state (exited or crashed).
    public var isTerminal: Bool {
        switch self {
        case .starting, .running: return false
        case .exited, .crashed: return true
        }
    }

    /// A short word for a status badge / window-title bracket: only a real signal
    /// kill reads as "crashed"; a non-zero exit reads as "exited".
    public var shortLabel: String {
        switch self {
        case .starting: return "starting"
        case .running: return "running"
        case .exited: return "exited"
        case .crashed: return "crashed"
        }
    }

    /// A clear, unobtrusive end-of-session line for the surface, so a terminated
    /// window reads as *finished*, not *hung*. `nil` while still live.
    public var endBanner: String? {
        switch self {
        case .starting, .running:
            return nil
        case .exited(let code):
            return "— session ended (exit \(code)) —"
        case .crashed(let signal):
            return "— session killed (signal \(signal)) —"
        }
    }
}
