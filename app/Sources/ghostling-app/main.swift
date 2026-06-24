import AppKit
import GhostlingApp

// The launchable, screenshottable Phase 01 app: a single window hosting one
// interactive shell in our embedded libghostty terminal. The hosted command can
// be overridden on the command line (e.g. a fake-agent fixture); the pool
// firewall still refuses `claude -p` before any window appears.
//
// Usage:  swift run ghostling-app [command [args...]]
//         (defaults to $SHELL)

let argv = Array(CommandLine.arguments.dropFirst())

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppShell(command: argv.isEmpty ? nil : argv)
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
