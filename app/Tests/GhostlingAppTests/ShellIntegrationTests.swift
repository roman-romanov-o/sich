import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// TC-UNIT-024 / US-004 AC1: cwd must be REPORTED semantically (OSC-7) off the LIVE PTY
/// output path — not INFERRED by scanning the process tree, and not merely parsed by a
/// dead helper. This drives real OSC-7 bytes THROUGH the same ingestion entry point the
/// read loop funnels every chunk through (`PTYSession.ingest`), with the app's own
/// wiring (`ShellSignalBridge`) installed exactly as `BoardShell` does at launch, and
/// asserts the OWNING SESSION's cwd updates — proving the parser is reachable from the
/// live stream, not orphaned. No spawn, no fd, no wall-clock: deterministic byte-state.
struct ShellIntegrationTests {
    @Test func cwdReportedNotInferred() throws {
        // A path the test process is provably NOT in, so a match can only be the
        // reported value — never one inferred from this process's real cwd.
        let declared = "/Users/operator/reported-not-scanned"
        #expect(declared != FileManager.default.currentDirectoryPath)

        // A managed shell session (ingest is the byte seam, so start() is unneeded) with
        // the app's real OSC-7 → cwd wiring attached exactly as BoardShell does.
        let pty = try PTYSession(command: ["/bin/zsh"])
        let session = Session(
            projectDir: "/launch/dir", agentType: .shell, flowTag: .interactive, pty: pty)
        ShellSignalBridge.attachCwdReporting(to: session)
        #expect(session.reportedCwd == nil)   // nothing reported before any output

        // Push an OSC-7 report (ST-terminated) THROUGH the real read-loop ingest path.
        pty.ingest(Array("\u{1B}]7;file://mac-host\(declared)\u{1B}\\".utf8))
        #expect(session.reportedCwd == declared)

        // A live `cd` to a second dir, BEL-terminated, updates the reported cwd again.
        let second = "/Users/operator/after-cd"
        pty.ingest(Array("\u{1B}]7;file://mac-host\(second)\u{07}".utf8))
        #expect(session.reportedCwd == second)

        // The real read loop chunks output arbitrarily: an OSC-7 SPLIT across two reads
        // must still resolve (proving the scanner buffers across chunk boundaries).
        let third = "/Users/operator/split-read"
        let seq = Array("\u{1B}]7;file://mac-host\(third)\u{1B}\\".utf8)
        pty.ingest(Array(seq[0..<6]))
        pty.ingest(Array(seq[6...]))
        #expect(session.reportedCwd == third)

        // OSC 0 (title set) carries no cwd → the reported cwd is unchanged; the
        // mechanism never guesses or scans the process tree to fill it in.
        pty.ingest(Array("\u{1B}]0;some title\u{1B}\\".utf8))
        #expect(session.reportedCwd == third)
    }
}
