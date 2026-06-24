import AppKit
import GhostlingApp

// The launchable, screenshottable Phase 03 mission-control board: state columns ×
// two-flow swimlanes, a "who needs me" attention count, and click-to-drill-in to a
// session's embedded terminal (US-002/003/005). It seeds a spread of fake-agent
// sessions across states so the board can be populated and captured — every
// session launches through the pool firewall (never `claude -p`).
//
// Usage:  swift run ghostling-board

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = BoardShell()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
