import Foundation
import Testing
@testable import SichCore

// Closes the gap the headless suite missed, end-to-end through the REAL registry
// reconcile path: a session that ends via a deliberate logout carrying a non-zero
// `$?` exits CLEANLY (WIFEXITED) with that code. The registry records it as
// `.crashed(code)` (frozen, correct at the logic layer), but the USER-FACING
// disposition must read as a clean EXIT — never "crashed" (US-001 Edge Case 2 /
// TC-E2E-104). This is the operator's case: Ctrl-C left `$?=130`, then Ctrl-D
// logged the shell out, which exited WIFEXITED with code 130 yet the window read
// "[crashed]".
//
// We reproduce the *lifecycle* deterministically with `sh -c 'exit <code>'`
// (an immediate WIFEXITED non-zero exit — the same class the registry sees on an
// EOF logout) instead of driving an interactive `zsh -i` through the PTY: whether
// an interactive shell exits on a single EOF is job-control/timing dependent and
// hangs the headless harness (a blocking teardown wait on a shell that never
// exits). The keystroke encoding itself (0x03/0x04) is covered in `KeyEncoderTests`;
// the synthesized-status disposition mapping in `SessionDispositionTests`. This
// test binds them through the real `SessionRegistry.launch → reconcile` path.

@Suite("Logout disposition through the real registry path")
struct LogoutDispositionEndToEndTests {

    /// Spin the reconcile loop until the session leaves the live set, mirroring
    /// `SessionRegistryTests.waitUntilDead`. The child exits immediately, so this
    /// converges in one or two passes (no interactive shell to hang on).
    private func waitUntilDead(_ registry: SessionRegistry, deadline: TimeInterval = 5) {
        let end = Date().addingTimeInterval(deadline)
        while !registry.live.isEmpty && Date() < end {
            registry.reconcile()
            usleep(20_000)
        }
    }

    @Test("a non-zero-code logout surfaces as a clean EXIT through the registry, not crashed",
          arguments: [Int32(130), 1])
    func nonZeroLogoutIsCleanExit(_ code: Int32) throws {
        let registry = SessionRegistry()
        let session = try registry.launch(
            command: ["/bin/sh", "-c", "exit \(code)"],
            projectDir: "/tmp/proj",
            agentType: .shell,
            flowTag: .interactive
        )
        defer { session.pty.finish() }   // child already dead → returns at once

        waitUntilDead(registry)
        try #require(registry.live.isEmpty, "session did not reach a terminal state")

        // The registry, by its frozen contract, lumps the non-zero exit into
        // `.crashed(ProcessExit)` — assert that so this test stays honest about
        // what it is exercising end-to-end.
        guard case .crashed(let exit) = session.state, exit.code == code, exit.signal == nil else {
            Issue.record("expected registry .crashed(code: \(code)), got \(session.state)")
            return
        }

        // The load-bearing assertion: the USER-FACING disposition of that same
        // state is a clean EXIT — never "crashed" — even with a non-zero code.
        let disposition = SessionDisposition(state: session.state)
        #expect(disposition == .exited(code: code))
        #expect(disposition.shortLabel == "exited")
        #expect(disposition.shortLabel != "crashed")
        #expect(disposition.endBanner == "— session ended (exit \(code)) —")
    }
}
