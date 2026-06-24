// swift-tools-version: 6.0
import PackageDescription

// Ghostling — the macOS-native Swift/AppKit app that embeds libghostty and
// becomes the terminal for managed agentic-coding sessions (see DD-001).
//
// Phase 01 (Terminal Foundation, US-001) first slice:
//   - vendor `ghostty-vt.xcframework` (proven in the Phase 00 spike) as a binary target,
//   - wrap the C API in a safe Swift `Terminal`,
//   - do the in-app, in-process PTY read in Swift (the keystone US-004 capability),
//   - enforce the pool firewall in code (interactive `claude` only; never `claude -p`).
//
// fork()/execvp() live in the `CPtySupport` C target so the child between fork and
// exec never touches the Swift runtime (async-signal-safety).
let package = Package(
    name: "Ghostling",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            path: "Frameworks/ghostty-vt.xcframework"
        ),
        .target(
            name: "CPtySupport"
        ),
        .target(
            name: "GhostlingCore",
            dependencies: ["GhosttyVt", "CPtySupport"]
        ),
        // AppKit window layer: `TerminalSurface` (renders one PTY) + `AppShell`
        // (window/app lifecycle). Kept thin — the testable transforms live in
        // GhostlingCore (KeyEncoder, Terminal.lines, SessionRegistry).
        .target(
            name: "GhostlingApp",
            dependencies: ["GhostlingCore"]
        ),
        .executableTarget(
            name: "ghostling-probe",
            dependencies: ["GhostlingCore"]
        ),
        // The launchable, screenshottable single-window shell pane.
        .executableTarget(
            name: "ghostling-app",
            dependencies: ["GhostlingApp"]
        ),
        // The launchable, screenshottable Phase 03 mission-control board
        // (state columns × two-flow swimlanes + attention count + drill-in).
        .executableTarget(
            name: "ghostling-board",
            dependencies: ["GhostlingApp"]
        ),
        .testTarget(
            name: "GhostlingCoreTests",
            dependencies: ["GhostlingCore"]
        ),
        // AppKit interaction tests — drive the real view hierarchy (drill-in hides
        // the board; ‘← board’ restores it) so the US-002 wiring is covered by a
        // test that exercises the view, not just the BoardSelection value type.
        .testTarget(
            name: "GhostlingAppTests",
            dependencies: ["GhostlingApp", "GhostlingCore"]
        ),
    ]
)
