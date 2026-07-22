import Foundation
import Testing
@testable import SichCore

// SessionRegistry is the single source of truth Phase 02/03 read from. Its
// load-bearing invariant (TC-E2E-104, at the logic level): a session is never
// left `running` once its process dies — neither on a clean exit nor on an
// abrupt kill.

@Suite("Session registry lifecycle")
struct SessionRegistryTests {

    /// Spin the reconcile loop briefly until the session leaves the live set.
    private func waitUntilDead(_ registry: SessionRegistry, deadline: TimeInterval = 5) {
        let end = Date().addingTimeInterval(deadline)
        while !registry.live.isEmpty && Date() < end {
            registry.reconcile()
            usleep(20_000)
        }
    }

    @Test("a launched session is registered with its metadata and marked running")
    func launchTracksMetadata() throws {
        let registry = SessionRegistry()
        let session = try registry.launch(
            command: ["/bin/sh", "-c", "sleep 2"],
            projectDir: "/tmp/proj",
            agentType: .shell,
            flowTag: .interactive
        )
        defer { session.pty.finish() }

        #expect(registry.session(id: session.id) === session)
        #expect(session.projectDir == "/tmp/proj")
        #expect(session.agentType == .shell)
        #expect(session.flowTag == .interactive)
        #expect(session.state == .running)
    }

    @Test("a clean exit is reflected as .exited, not left running")
    func cleanExitReflected() throws {
        let registry = SessionRegistry()
        let session = try registry.launch(
            command: ["/bin/sh", "-c", "exit 0"],
            projectDir: "/tmp/proj",
            agentType: .shell
        )
        waitUntilDead(registry)
        #expect(session.state == .exited)
        #expect(registry.live.isEmpty)
    }

    @Test("a non-zero exit is reflected as .crashed with the exit code")
    func nonZeroExitReflected() throws {
        let registry = SessionRegistry()
        let session = try registry.launch(
            command: ["/bin/sh", "-c", "exit 3"],
            projectDir: "/tmp/proj",
            agentType: .shell
        )
        waitUntilDead(registry)

        #expect(registry.live.isEmpty)
        switch session.state {
        case .crashed(let exit):
            #expect(exit.code == 3)
            #expect(exit.signal == nil)
            #expect(!exit.isClean)
        default:
            Issue.record("expected .crashed, got \(session.state)")
        }
    }

    @Test("an abrupt kill is reflected as .crashed, not left running")
    func abruptKillReflected() throws {
        let registry = SessionRegistry()
        let session = try registry.launch(
            command: ["/bin/sh", "-c", "sleep 30"],
            projectDir: "/tmp/proj",
            agentType: .shell
        )
        kill(session.pty.childPID, SIGKILL)
        waitUntilDead(registry)

        #expect(registry.live.isEmpty)
        switch session.state {
        case .crashed(let exit):
            #expect(exit.signal == SIGKILL)
            #expect(!exit.isClean)
        default:
            Issue.record("expected .crashed, got \(session.state)")
        }
    }

    @Test("launch passes through the pool firewall (no headless claude)")
    func launchRefusesHeadless() {
        let registry = SessionRegistry()
        #expect(throws: PoolViolation.self) {
            try registry.launch(
                command: ["claude", "-p", "headless"],
                projectDir: "/tmp/proj",
                agentType: .claude
            )
        }
        #expect(registry.all.isEmpty)
    }
}
