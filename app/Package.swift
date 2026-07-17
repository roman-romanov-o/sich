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
    dependencies: [
        // YAML parsing for saha/v2 task tracking (`progress.yaml`).
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
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
            dependencies: ["GhosttyVt", "CPtySupport",
                           .product(name: "Yams", package: "Yams")]
        ),
        // AppKit window layer: `TerminalSurface` (renders one PTY) + `BoardShell`
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
        // The one assembled product binary: board + quota side-panel + drill-in
        // terminal in a single window (replaces the old per-surface app/board/quota
        // prototype binaries). Two Anthropic pools stay never-netted; pool firewall
        // refuses `claude -p`.
        .executableTarget(
            name: "ghostling",
            dependencies: ["GhostlingApp"]
        ),
        .testTarget(
            name: "GhostlingCoreTests",
            dependencies: ["GhostlingCore"],
            resources: [.copy("Fixtures")]
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
