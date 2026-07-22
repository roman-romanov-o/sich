import Foundation
import Testing
@testable import SichCore

// The user-facing presentation classification, tested window-free. The registry
// (frozen) lumps every non-zero outcome into `.crashed(ProcessExit)`; the
// surface must NOT. The governing contract:
//   - US-001 Edge Case 2: a deliberate logout must "show the exit cleanly".
//   - TC-E2E-104: a "crash" is an ABRUPT kill (a terminating SIGNAL), not a
//     non-zero EXIT code.
// So a clean WIFEXITED process is an EXIT for any code; only WIFSIGNALED is a
// crash. This is the bug an interactive Ctrl-C-then-Ctrl-D logout ($?=130) hit:
// it exited cleanly with code 130 yet the window read "[crashed]".

@Suite("Session disposition (user-facing lifecycle presentation)")
struct SessionDispositionTests {

    /// A WIFEXITED raw `waitpid` status carrying the given exit code (code in the
    /// high byte, low 7 bits zero ⇒ "exited"), mirroring `ProcessExit`'s decode.
    private func exitedStatus(code: Int32) -> Int32 { (code & 0xFF) << 8 }

    @Test("a clean .exited maps to exited(0)")
    func cleanExit() {
        let d = SessionDisposition(state: .exited)
        #expect(d == .exited(code: 0))
        #expect(d.shortLabel == "exited")
        #expect(d.isTerminal)
    }

    @Test("a SIGNAL death maps to crashed — the only true crash (TC-E2E-104)")
    func signalIsCrash() {
        let exit = ProcessExit(rawStatus: SIGKILL)   // WIFSIGNALED
        #expect(exit.signal == SIGKILL)
        let d = SessionDisposition(state: .crashed(exit))
        #expect(d == .crashed(signal: SIGKILL))
        #expect(d.shortLabel == "crashed")
        #expect(d.endBanner == "— session killed (signal \(SIGKILL)) —")
    }

    @Test("a non-zero EXIT maps to exited(code), NOT crashed", arguments: [
        Int32(1), 3, 130,
    ])
    func nonZeroExitIsNotCrash(_ code: Int32) {
        let exit = ProcessExit(rawStatus: exitedStatus(code: code))   // WIFEXITED
        #expect(exit.code == code)
        #expect(exit.signal == nil)

        let d = SessionDisposition(state: .crashed(exit))
        #expect(d == .exited(code: code))           // exit, not crash
        #expect(d.shortLabel == "exited")
        #expect(d.shortLabel != "crashed")
        #expect(d.endBanner == "— session ended (exit \(code)) —")
    }

    @Test("live states are not terminal and have no end banner")
    func liveStates() {
        for state: SessionState in [.starting, .running] {
            let d = SessionDisposition(state: state)
            #expect(!d.isTerminal)
            #expect(d.endBanner == nil)
        }
    }
}
