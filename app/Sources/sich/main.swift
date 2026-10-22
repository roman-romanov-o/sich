import AppKit
import SichApp
import SichCore

// Sich — the single assembled app (DD-001 "become the terminal"): ONE window
// hosting the mission-control board (state columns × two-flow swimlanes + "who
// needs me"), the quota panel (four never-netted gauges) as a side region, and
// click-to-drill-in into a session's real embedded libghostty terminal. This
// replaces the three single-surface prototype binaries (app/board/quota) with the
// one product surface. Every session launches through the pool firewall — never
// `claude -p`.
//
// Usage:  swift run sich

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// Daily-use launch: NO seeded cards at all. The board is exactly the operator's
// persisted task book plus whatever live hook-observed sessions the event-file tail
// merges onto it; ⌘N (the create palette) is how a new card is born. Quota is the
// live in-process feed (no sidecar, no port — DD-001/DD-002).
//
// A single unconditional `liveTerminal` seed used to ride every launch — the
// pre-create-palette way to make DD-001 ("we are the terminal") visible on an empty
// board. It outlived its job: the palette, the task book and the hook feed each own
// a piece of what it demonstrated, and the card it drew was never a task (it is
// filtered out of `persistTasks`), which contradicts the board's own premise that a
// card IS a task. Launched from the .app bundle it was also wrong on its face: cwd
// `/` resolves no repo root, so the seed landed on the home dir and drew a card
// named after the user.
//
// `SICH_E2E=1` (the design-review capture) still presents a representative
// portfolio so the screenshots show a populated board + the two-pool quota contrast
// the critique exists to judge: one real terminal as `cards.first` (a real terminal
// shot for the drill-in) with the rich demo spread behind it, and demo quota.
let isE2E = ProcessInfo.processInfo.environment["SICH_E2E"] != nil
// Developer hot code swapping (InjectionIII). DEBUG-only and never during the E2E
// capture, so it can't perturb the screenshots; a no-op if InjectionIII isn't
// installed. Run via `./dev.sh` to get the `-Xlinker -interposable` flag it needs.
if !isE2E { DevHotReload.enable() }
// The real app launch is the ONLY place the hidden `/usage` probe may spawn
// claude/agent — tests and the E2E capture never set this, so they never start a process.
HiddenTUIProbe.spawningEnabled = !isE2E
// Same discipline for the remote hook channel: only the real launch may run `ssh`,
// so `swift test` and the capture can never reach the network (US-005).
SSHCommandRunner.spawningEnabled = !isE2E
RemoteHookStatus.probingEnabled = !isE2E
// …and for the per-host event relay (`ssh … tail -F`), which is the only thing that
// makes a remote agent observable at all (US-003).
SSHLineTransport.spawningEnabled = !isE2E
let delegate = isE2E
    ? BoardShell(
        seeds: [BoardSeed.liveTerminal(projectDir: RepoLocator.launchProjectDir())]
            + BoardSeed.demo,
        sources: QuotaSeed.demo)
    : BoardShell(seeds: [],
                 sources: QuotaSeed.connecting)   // honest "unknown" until the poller lands
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
