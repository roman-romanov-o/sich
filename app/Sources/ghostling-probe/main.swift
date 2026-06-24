import Foundation
import GhostlingCore

// A runnable, headless demonstration of the Phase 01 keystone: open a managed
// session on a command, read its pty output in-process via libghostty-vt, and
// print the rendered screen. Every launch passes the pool firewall first.
//
// Usage:  swift run ghostling-probe [command [args...]]
//         (defaults to `/bin/echo hello from ghostling`)

let argv = Array(CommandLine.arguments.dropFirst())
let command = argv.isEmpty ? ["/bin/echo", "hello from ghostling"] : argv

do {
    let session = try PTYSession(command: command)
    try session.start()
    let bytes = session.drainToEOF()
    session.finish()

    let screen = try session.terminal.plainText()
    print("---- in-process PTY read: \(bytes) bytes (pool: \(session.pool)) ----")
    print(screen)
    print("----------------------------------------------------------------")
} catch let violation as PoolViolation {
    FileHandle.standardError.write(Data("pool firewall: \(violation)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
