import Foundation
import Testing
@testable import SichCore

/// The pty child must start with only its terminal (0/1/2) open. `forkpty`
/// hands the child a copy of EVERY descriptor the app holds — other cards' pty
/// masters, the pipes of a running git/ssh helper — so a child that outlives the
/// helper keeps the pipe's write end open and the app's read never sees EOF
/// (the full test suite hung exactly there), and closing a card's master cannot
/// hang up its child while a sibling child still holds a copy.
@Suite("pty child descriptor hygiene")
struct PTYChildDescriptorTests {

    @Test("a pty child inherits nothing beyond stdin/stdout/stderr")
    func childSeesOnlyItsTerminal() throws {
        // Something open in the parent at fork time, as a helper's pipe would be.
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let pty = try PTYSession(command: ["/bin/sh", "-c", "echo /dev/fd/*; echo done"], rows: 10, cols: 40)
        try pty.start()
        pty.setNonBlocking()
        defer { pty.terminate() }

        let deadline = Date().addingTimeInterval(5)
        var text = ""
        while Date() < deadline, !text.contains("done") {
            _ = pty.pumpAvailable()
            text = (try? pty.terminal.plainText()) ?? ""
            Thread.sleep(forTimeInterval: 0.02)
        }
        // The shell's glob is the only descriptor the child opens on its own (3,
        // the directory it reads) — `ls` would add a second of its own.
        let fds = text.split(whereSeparator: \.isWhitespace)
            .compactMap { $0.hasPrefix("/dev/fd/") ? Int($0.dropFirst("/dev/fd/".count)) : nil }
        #expect(fds == [0, 1, 2, 3], "the child inherited descriptors: \(fds) — screen: \(text)")
    }
}
