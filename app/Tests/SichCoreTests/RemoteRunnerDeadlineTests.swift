import Foundation
import Testing

@testable import SichCore

/// Checklist 18.08, item 11: a Tailscale host waiting for a browser re-auth ACCEPTS
/// the ssh connection and then holds it silently — ssh neither answers nor exits, so
/// the app's synchronous probes (drill-in revival, the ⌘⇧R conflict check) froze the
/// UI until the operator authed. The runner now kills any command at its deadline and
/// answers `nil`, which the probe layer already reads as "silence — proceed": the
/// pane still attaches, and the auth URL prints there for the operator to follow.
struct RemoteRunnerDeadlineTests {

    @Test("a command that hangs past the deadline is killed and answers nil")
    func hungCommandIsBounded() {
        let started = Date()
        let result = SSHCommandRunner.bounded(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"],
            input: nil, deadline: 0.5)
        let elapsed = Date().timeIntervalSince(started)

        #expect(result == nil, "a hang is transport silence, never a success")
        #expect(elapsed < 5, "the wait is the deadline, not the hang — took \(elapsed)s")
    }

    @Test("partial output before the hang is not promoted to an answer")
    func partialOutputDoesNotMaskTheHang() {
        let result = SSHCommandRunner.bounded(
            executable: "/bin/sh", arguments: ["-c", "echo partial; sleep 30"],
            input: nil, deadline: 0.5)
        #expect(result == nil,
                "half a probe answer classified as .foreign/.absent would be worse than none")
    }

    @Test("a command that answers in time still comes back whole")
    func promptCommandStillSucceeds() throws {
        let result = try #require(SSHCommandRunner.bounded(
            executable: "/bin/echo", arguments: ["still-works"],
            input: nil, deadline: 10))
        #expect(result.succeeded)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "still-works\n")
    }

    @Test("stdin still reaches a bounded command")
    func inputStillFlows() throws {
        let result = try #require(SSHCommandRunner.bounded(
            executable: "/usr/bin/wc", arguments: ["-c"],
            input: Data("12345".utf8), deadline: 10))
        #expect(result.succeeded)
        let count = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(count == "5")
    }

    @Test("the spawn gate still holds: no probe leaves swift test")
    func spawnGateStillHolds() {
        #expect(SSHCommandRunner.spawningEnabled == false)
        let result = SSHCommandRunner(deadline: 0.5).run(argv: ["/bin/echo", "hi"], input: nil)
        #expect(result == nil, "run() stays inert under tests even for a local binary")
    }
}
