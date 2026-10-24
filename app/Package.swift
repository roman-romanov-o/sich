// swift-tools-version: 6.0
import PackageDescription

// Sich — the macOS-native Swift/AppKit app that embeds libghostty and
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
    name: "Sich",
    platforms: [.macOS(.v14)],  // NSView.displayLink (CADisplayLink) needs 14+
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            path: "Frameworks/ghostty-vt.xcframework"
        ),
        .target(
            name: "CPtySupport"
        ),
        .target(
            name: "SichCore",
            dependencies: ["GhosttyVt", "CPtySupport"]
        ),
        // AppKit window layer: `TerminalSurface` (renders one PTY) + `BoardShell`
        // (window/app lifecycle). Kept thin — the testable transforms live in
        // SichCore (KeyEncoder, Terminal.lines, SessionRegistry).
        .target(
            name: "SichApp",
            dependencies: ["SichCore"],
            // Official harness marks (Anthropic/OpenAI/Google Gemini) as vector PDFs,
            // rendered crisp+tinted by `HarnessBadge` in place of unicode approximations.
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "sich-probe",
            dependencies: ["SichCore"]
        ),
        // The one assembled product binary: board + quota side-panel + drill-in
        // terminal in a single window (replaces the old per-surface app/board/quota
        // prototype binaries). Two Anthropic pools stay never-netted; pool firewall
        // refuses `claude -p`.
        .executableTarget(
            name: "sich",
            dependencies: ["SichApp"]
        ),
        .testTarget(
            name: "SichCoreTests",
            dependencies: ["SichCore"],
            resources: [.copy("Fixtures")]
        ),
        // AppKit interaction tests — drive the real view hierarchy (drill-in hides
        // the board; ‘← board’ restores it) so the US-002 wiring is covered by a
        // test that exercises the view, not just the BoardSelection value type.
        .testTarget(
            name: "SichAppTests",
            dependencies: ["SichApp", "SichCore"]
        ),
    ]
)
