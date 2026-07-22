import AppKit
import GhostlingApp
import GhostlingCore

// Ghostling — the single assembled app (DD-001 "become the terminal"): ONE window
// hosting the mission-control board (state columns × two-flow swimlanes + "who
// needs me"), the quota panel (four never-netted gauges) as a side region, and
// click-to-drill-in into a session's real embedded libghostty terminal. This
// replaces the three single-surface prototype binaries (app/board/quota) with the
// one product surface. Every session launches through the pool firewall — never
// `claude -p`.
//
// Usage:  swift run ghostling

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// Daily-use launch: NOT the fake demo spread — a single REAL interactive terminal
// card (your login shell, drillable; run `claude` in it) plus whatever live
// hook-observed sessions the event-file tail merges onto the board. Quota is the
// live in-process feed (no sidecar, no port — DD-001/DD-002).
let root = RepoLocator.launchProjectDir()
// `GHOSTLING_E2E=1` (the design-review capture) presents a representative portfolio
// so the screenshots show a populated board + the two-pool quota contrast the
// critique exists to judge: the live terminal stays `cards.first` (a real terminal
// shot for the drill-in) with the rich demo spread behind it, and demo quota. A
// daily launch stays honest — one real terminal + all-"unknown" connecting quota.
let isE2E = ProcessInfo.processInfo.environment["GHOSTLING_E2E"] != nil
// Developer hot code swapping (InjectionIII). DEBUG-only and never during the E2E
// capture, so it can't perturb the screenshots; a no-op if InjectionIII isn't
// installed. Run via `./dev.sh` to get the `-Xlinker -interposable` flag it needs.
if !isE2E { DevHotReload.enable() }
// The real app launch is the ONLY place the hidden `/usage` probe may spawn
// claude — tests and the E2E capture never set this, so they never start a process.
ClaudeUsageProbe.spawningEnabled = !isE2E
let delegate = isE2E
    ? BoardShell(seeds: [BoardSeed.liveTerminal(projectDir: root)] + BoardSeed.demo,
                 sources: QuotaSeed.demo)
    : BoardShell(seeds: [BoardSeed.liveTerminal(projectDir: root)],
                 sources: QuotaSeed.connecting)   // honest "unknown" until the poller lands
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
