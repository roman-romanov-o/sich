import AppKit
import GhostlingCore
import UserNotifications

/// The board window: hosts the mission-control ``BoardView``, the
/// ``AttentionIndicator`` header, and the ``DrillInPanel`` overlay, wired to a
/// ``SessionRegistry`` of seeded sessions. This is the launchable,
/// screenshottable Phase 03 surface (US-002/003/005 rendering).
///
/// It owns the live model: a `[BoardCard]` snapshot plus the map from card id →
/// `PTYSession` so a drill-in (US-002) can mount the right embedded terminal. It
/// never spawns `claude -p` — every session launches through the registry's pool
/// firewall.
@MainActor
public final class BoardShell: NSObject, NSApplicationDelegate {
    private let registry = SessionRegistry()
    private let seeds: [BoardSeed]
    private var quotaSources: [QuotaSourceInput]

    private var window: NSWindow?
    // Internal (not private) so a real view-level test can assert the drill-in
    // hierarchy — the iter-2 sign-off proved BoardSelection's value-type test does
    // not cover whether the board is actually hidden / restored on screen.
    let boardView = BoardView()
    let attention = AttentionIndicator()
    let fontControls = FontSizeControls(scope: .board)
    let drillIn = DrillInPanel()
    let planningMode = PlanningModeView()
    private(set) var sahaTaskChooser: SahaTaskChooserView?
    private(set) var createPalette: CreateCardPalette?
    // The quota panel folded in as a right-side region — one assembled window
    // shows the board AND the four never-netted gauges (no separate binary).
    let quota = QuotaPanel()
    // The live data bridge — fully native after the Phase-03 cutover (DD-001/DD-002):
    // quota reads in-process from disk (no `GET /quota`, no sidecar) and sessions
    // arrive by tailing the observe-only event file (no `/sessions`, no port).
    // Started only on the real launch path (not in tests).
    private var quotaPoller: NativeQuotaPoller?
    private var sessionsPoller: SessionsPoller?
    private var turnDiffs: [TurnDiff] = []
    // The always-on pty drain (the fix for "work stops when I leave the task"): one
    // main-run-loop timer that reads EVERY owned session's pty each tick — not just
    // the drilled-in one — so an off-screen agent's child never blocks on a full
    // kernel buffer. Its own surface drains the drilled-in card, so the pump skips it.
    private var sessionPumpTimer: Timer?
    // Ctrl+Tab task-switch monitor — retained so it can be torn down; installed only
    // on the real launch path, never the headless test build (tests drive cycleDrill
    // and switchDirection directly, so no event-loop dependency).
    private var taskSwitchMonitor: Any?
    private(set) var drilledInCardID: UUID?
    // Pump ticks since launch — the reconcile pass piggybacks on the pump timer at
    // a ~1s cadence (one waitpid(WNOHANG) per live session; no extra timer).
    private var pumpTick = 0
    // Cards whose child died WHILE drilled in: the surface shows the end banner
    // first; the card is swept off the board when the operator returns to it.
    private var deadCardIDs: Set<UUID> = []
    // Attention count at the previous render — alerts fire only on a RISE.
    private var lastAttentionCount = 0
    // Per-card state at the previous render — a "task done" notification fires on
    // the rising edge into `.done` (not every refresh while it stays done).
    private var lastCardStates: [UUID: CardState] = [:]
    // Last applied live-session snapshot signature — re-render only on a real change
    // so the 3s poll doesn't tear down and rebuild identical card views (flicker).
    private var lastSessionsSignature: [String] = []
    private var idleHoldUntil: [UUID: Date] = [:]
    // User intent, not detector output: only a manual drop to DONE survives a restart
    // as DONE. Everything else starts from queue and must earn WORKING again from
    // fresh observations in the current app session.
    private var manuallyDoneCardIDs: Set<UUID> = []
    // A card manually moved out of DONE must not be pulled straight back by the stale
    // finished run still present in the hook/session feed. Let fresh work reopen the
    // automatic done path.
    private var manuallyReopenedDoneCardIDs: Set<UUID> = []

    private var selection = BoardSelection()
    private(set) var cards: [BoardCard] = []
    private(set) var planningModeCardID: UUID?
    private var ptyByCard: [UUID: PTYSession] = [:]
    var launchOverrideForTesting: ((BoardSeed) -> Session?)?
    /// Provisions one git worktree per task (`createSession(inWorktree:)`) —
    /// injectable so tests never mint real worktrees in this repo.
    var worktreeProvisioner: any WorktreeProvisioning = GitWorktreeProvisioner()
    // Repo root for the live-terminal cwd and the hook installer (resolved once).
    private let repoRoot = RepoLocator.repoRoot()
    // Monotonic suffix so each "+ new session" card gets a unique sessionID.
    private var sessionCounter = 0
    private var terminalFontSize: CGFloat = 20

    /// - Parameters:
    ///   - seeds: the sessions to populate the board with (defaults to the demo
    ///     spread). Each launches a firewall-clean fake agent — never `claude -p`.
    ///   - sources: the quota sources to render in the side panel (defaults to the
    ///     demo four-pool fixture; a live poller replaces this in Phase 2). `var`
    ///     so the poller can swap in fresh readings and re-`refresh()`.
    public init(seeds: [BoardSeed] = BoardSeed.demo,
                sources: [QuotaSourceInput] = QuotaSeed.demo) {
        self.seeds = seeds
        self.quotaSources = sources
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        BoardTheme.boardFontScale = 1.2
        makeWindow()
        installMainMenu()
        installTaskSwitchMonitor()
        wireInteractions()
        refresh()
        // First paint should not wait for shell/PTY spawns, saved-session restore,
        // quota disk walks, event-tail setup, or idempotent integration installs.
        // Build and order the window first; hydrate the board just after AppKit gets
        // a chance to present that empty-but-usable shell.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.finishStartupAfterFirstPaint()
        }
    }

    private func finishStartupAfterFirstPaint() {
        // US-003: reload + re-open the pre-quit session tree before the fresh seed lands.
        restorePreviousSessions()
        seedSessions()
        refresh()
        startSessionPump()
        startQuotaBridge()
        installPostLaunchIntegrations()
        handleLaunchCaptureRequests()
        maybeRunE2E()
    }

    private func handleLaunchCaptureRequests() {
        // Capture seam: `GHOSTLING_OPEN_PALETTE=1` opens the ⌘N create palette on launch
        // so a screenshot tool can grab the real composited chrome (not a CALayer render).
        if ProcessInfo.processInfo.environment["GHOSTLING_OPEN_PALETTE"] != nil {
            openCreatePalette()
            // Capture the richest stage without keystroke automation: jump straight in.
            let stage = ProcessInfo.processInfo.environment["GHOSTLING_PALETTE_STAGE"]
            if let dir = recentProjectDirs().first {
                if stage == "task" {
                    let real = TaskFolderIndex().discover(in: URL(fileURLWithPath: dir, isDirectory: true))
                    let folders = real.isEmpty ? Self.demoTaskFolders(dir) : real
                    createPalette?.presentSahaTaskStage(projectDir: dir, folders: folders)
                } else if stage == "harness" {
                    createPalette?.presentHarnessStage(projectDir: dir)
                }
            }
            if let n = window?.windowNumber { FileHandle.standardError.write(Data("GHOSTLING_WINDOW=\(n)\n".utf8)) }
        }
        // Capture seam: `GHOSTLING_OPEN_PLANNING=<taskFolder>` enters Planning Mode against
        // a real task folder so a screenshot can verify the markdown doc pane renders.
        if let folder = ProcessInfo.processInfo.environment["GHOSTLING_OPEN_PLANNING"] {
            let dir = recentProjectDirs().first ?? folder
            enterPlanningMode(BoardCard(
                sessionID: "planning", projectDir: dir, agent: .claude,
                flow: .a, state: .idle, taskFolder: folder))
            // Capture seam: `GHOSTLING_OPEN_FILEREF=<ref>` drives straight into the file viewer
            // so a screenshot can verify the "← doc" back affordance.
            if let ref = ProcessInfo.processInfo.environment["GHOSTLING_OPEN_FILEREF"] {
                planningMode.openFileRef(ref)
            }
            if let n = window?.windowNumber { FileHandle.standardError.write(Data("GHOSTLING_WINDOW=\(n)\n".utf8)) }
        }
    }

    /// `GHOSTLING_E2E=1` → once the window has rendered and the first native poll has
    /// had time to land, run the on-screen smoke and exit with its verdict.
    /// No-op for a normal launch (the harness is never even constructed).
    private func maybeRunE2E() {
        guard ProcessInfo.processInfo.environment["GHOSTLING_E2E"] != nil,
              let window else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            E2EHarness(shell: self, window: window).run()
        }
    }

    /// Best-effort cleanup before the E2E harness hard-exits with a status code
    /// (`exit()` skips `applicationWillTerminate`): stop the pollers and SIGTERM the
    /// shells we forked so a run doesn't leak login shells.
    func e2eTeardown() {
        stopSessionPump()
        quotaPoller?.stop()
        sessionsPoller?.stop()
        for pty in ptyByCard.values { pty.terminate() }
    }

    /// E2E-only: write raw bytes to a card's owned PTY, so a capture can exercise a
    /// real end-to-end path before screenshotting — e.g. send a `printf` with ANSI
    /// SGR codes through the live shell so the drill-in shot actually shows colour.
    func e2eSend(_ bytes: [UInt8], into card: BoardCard) {
        ptyByCard[card.id]?.send(bytes)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stopSessionPump()
        quotaPoller?.stop()
        sessionsPoller?.stop()
        // US-003: persist the live window/pane tree BEFORE tearing the shells down, so
        // each pane's child PID is still valid for the reopen-vs-dead decision next launch.
        persistOnTerminate(store: SessionSnapshotStore.applicationSupport())
        // Kill every live shell we own (non-blocking) — otherwise the forked
        // $SHELL -il processes outlive the app, and finish()'s blocking waitpid
        // would hang on a shell still sitting at its prompt.
        for pty in ptyByCard.values { pty.terminate() }
    }

    /// Bring up the live data feed — fully native, no sidecar, no port (DD-001/DD-002):
    /// quota reads IN-PROCESS on a timer, and sessions arrive by tailing the
    /// observe-only event file. Degrades gracefully — the seeded gauges stay until the
    /// first read lands.
    private func startQuotaBridge() {
        // In E2E (design-review capture) keep the seeded two-pool demo quota on
        // screen: the native reader would overwrite it with the honest interactive +
        // all-"unknown" reading (no provider wiring yet for the other three pools),
        // hiding the pool contrast the capture exists to show.
        if ProcessInfo.processInfo.environment["GHOSTLING_E2E"] == nil {
            let poller = NativeQuotaPoller { [weak self] sources in self?.applyQuota(sources: sources) }
            poller.start()
            self.quotaPoller = poller
        }
        let sessionsPoller = SessionsPoller(
            diffSink: { [weak self] diffs in
                self?.turnDiffs = diffs
                self?.drillIn.update(diffs: diffs)
            },
            sink: { [weak self] cards in self?.applySessions(cards) }
        )
        sessionsPoller.start()
        self.sessionsPoller = sessionsPoller
    }

    // MARK: - Always-on pty drain

    /// Start the background pty pump: a main-run-loop timer that drains every owned
    /// session each tick so a child never blocks on a full kernel buffer while its
    /// terminal is off-screen (the "work stops when I leave the task" fix). Idempotent.
    /// Called on the real launch path; a test starts it explicitly.
    func startSessionPump() {
        guard sessionPumpTimer == nil else { return }
        schedulePump(hz: Self.pumpActiveHz)
    }

    func stopSessionPump() {
        sessionPumpTimer?.invalidate()
        sessionPumpTimer = nil
    }

    // Adaptive cadence, mirroring TerminalSurface: 30Hz while any background child
    // produces output, 4Hz once ALL have been quiet ~1s. Back-pressure safety is
    // unaffected — even 4Hz full drains outrun a ~64KB tty buffer for a quiet child,
    // and the first busy tick upshifts again.
    // ponytail: still polling non-blocking fds; swap for kqueue only if the 4Hz
    // idle wakeups ever show up in a power profile.
    private static let pumpActiveHz = 30.0
    private static let pumpIdleHz = 4.0
    private var pumpIdleTicks = 0
    private var pumpHz = pumpActiveHz

    private func schedulePump(hz: Double) {
        sessionPumpTimer?.invalidate()
        pumpHz = hz
        let timer = Timer(timeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pumpBackgroundSessions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionPumpTimer = timer
    }

    /// Drain every owned session EXCEPT the one drilled in (its `TerminalSurface`
    /// owns that fd — draining it here too would race the surface's reader and steal
    /// the bytes it repaints from). One reader per fd at all times.
    private func pumpBackgroundSessions() {
        pumpTick += 1
        if pumpTick % Int(pumpHz) == 0 { reconcileDeadSessions() }   // ~1s cadence
        var sawData = false
        for (id, pty) in ptyByCard
        where id != drilledInCardID && id != planningModeCardID && pty.masterFD >= 0 {
            pty.setNonBlocking()          // idempotent
            drain: while true {
                switch pty.pumpAvailable() {
                case .data: sawData = true; continue drain
                case .idle, .eof: break drain
                }
            }
        }
        reconcileCodexChoiceScreens()
        adaptPumpCadence(sawData: sawData)
    }

    private func adaptPumpCadence(sawData: Bool) {
        if sawData {
            if pumpHz != Self.pumpActiveHz { schedulePump(hz: Self.pumpActiveHz) }
            pumpIdleTicks = 0
        } else {
            pumpIdleTicks += 1
            if pumpHz == Self.pumpActiveHz, pumpIdleTicks >= Int(Self.pumpActiveHz) {
                schedulePump(hz: Self.pumpIdleHz)   // ~1s of silence
            }
        }
    }

    /// Codex has no Claude-style `Notification` hook, so its request_user_input menu
    /// would otherwise sit in WORKING forever. Read the already-rendered emulator
    /// screen for owned Codex cards and turn the narrow choice UI into the same
    /// `.waitingForInput` state the board already understands.
    private func reconcileCodexChoiceScreens() {
        for (id, pty) in ptyByCard where pty.masterFD >= 0 {
            guard let screen = try? pty.terminal.plainText() else { continue }
            reconcileCodexChoiceScreen(cardID: id, screen: screen)
        }
    }

    func reconcileCodexChoiceScreensForTesting() {
        reconcileCodexChoiceScreens()
    }

    func reconcileCodexChoiceScreenForTesting(cardID: UUID, screen: String) {
        reconcileCodexChoiceScreen(cardID: cardID, screen: screen)
    }

    private func reconcileCodexChoiceScreen(cardID: UUID, screen: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }),
              cards[index].agent == .codex,
              cards[index].state != .done
        else { return }
        let waiting = CodexChoiceScreen.isWaitingForChoice(screen)
        if waiting, cards[index].state != .waitingForInput {
            cards[index] = cards[index].with(state: .waitingForInput)
            refresh()
        } else if !waiting, cards[index].state == .waitingForInput {
            cards[index] = cards[index].with(state: .running)
            refresh()
        }
    }

    /// Keep the board honest about death: poll every owned child (`waitpid` WNOHANG
    /// via the registry) and reflect any that exited or crashed. A dead card off
    /// screen is removed outright (its shell is gone — a stale card is a lie); the
    /// drilled-in card first shows the end banner on its surface and is swept when
    /// the operator returns to the board.
    @discardableResult
    func reconcileDeadSessions() -> [UUID] {
        var processed: [UUID] = []
        for session in registry.reconcile() {
            guard let cardID = ptyByCard.first(where: { $0.value === session.pty })?.key
            else { continue }
            processed.append(cardID)
            let disposition = SessionDisposition(state: session.state)
            if cardID == drilledInCardID {
                deadCardIDs.insert(cardID)
                drillIn.markEnded(disposition)
            } else {
                removeDeadCard(cardID)
            }
            registry.remove(id: session.id)
        }
        return processed
    }

    /// Drop a dead card: close its (already-reaped) pty fd and take it off the board.
    private func removeDeadCard(_ cardID: UUID) {
        ptyByCard.removeValue(forKey: cardID)?.finish()   // child reaped; just closes the fd
        cards.removeAll { $0.id == cardID }
        deadCardIDs.remove(cardID)
        refresh()
    }

    // MARK: - Session resume (US-003) + shell integration (US-004)

    /// US-003 launch side: on a normal launch, reload and re-open the pre-quit session
    /// tree. Skipped under `GHOSTLING_E2E` so the design-review capture shows only its
    /// scripted board, not whatever real shells were open last time. The restored cards
    /// are rendered by the launch `refresh()` that runs right after seeding.
    private func restorePreviousSessions() {
        guard ProcessInfo.processInfo.environment["GHOSTLING_E2E"] == nil else { return }
        restoreOnLaunch(store: SessionSnapshotStore.applicationSupport(),
                        restorer: makeLaunchRestorer())
    }

    /// US-003 quit side: persist the live window/pane tree so the next launch can restore
    /// it. Injectable store so a test drives the exact quit path into a temp app-support
    /// dir. Best-effort — a write failure just means no resume, never a crash on quit.
    @discardableResult
    func persistOnTerminate(store: SessionSnapshotStore) -> SessionSnapshot? {
        try? store.save(windows: enrichedSnapshotWindows())
    }

    /// The registry snapshot, enriched with each pane's app-level card metadata (identity,
    /// human title, column, saha task folder) so a restart brings the *task* back, not just
    /// an unnamed shell at the same cwd. Core builds panes from sessions and has no notion
    /// of a card, so the join belongs here in the app layer.
    private func enrichedSnapshotWindows() -> [WindowSnapshot] {
        registry.snapshotWindows().map { window in
            WindowSnapshot(panes: window.panes.map(enrich(pane:)))
        }
    }

    private func enrich(pane: PaneSnapshot) -> PaneSnapshot {
        guard let card = card(forSessionID: pane.sessionID) else { return pane }
        return pane.with(
            cardID: card.id, cardState: persistedRestartState(for: card),
            title: card.title, taskFolder: card.taskFolder
        )
    }

    private func persistedRestartState(for card: BoardCard) -> CardState {
        manuallyDoneCardIDs.contains(card.id) ? .done : .idle
    }

    /// The card driving a registry session — joined through the pty the two share
    /// (`ptyByCard`), NOT the card's `sessionID`: a created card's `sessionID` is a
    /// title slug, never the registry Session UUID, so a slug compare would silently
    /// match nothing and persist every card unnamed. The pty is the one identity the
    /// card and its session actually agree on (same join the hook binder uses).
    private func card(forSessionID sessionID: UUID) -> BoardCard? {
        guard let pty = registry.session(id: sessionID)?.pty,
              let cardID = ptyByCard.first(where: { $0.value === pty })?.key
        else { return nil }
        return cards.first { $0.id == cardID }
    }

    /// US-003 launch side: reload the pre-quit snapshot (or its `-previous` last-known-
    /// good on a corrupt/version-mismatched current) and restore its panes — the watcher
    /// invariant held by ``SessionRestorer`` (a plain `$SHELL -il` through the pool
    /// firewall, never `claude -p`). Injectable store + restorer so a test drives the
    /// exact path with a temp store and a spy restorer. Returns the restored panes; no
    /// snapshot → clean start (no-op).
    @discardableResult
    func restoreOnLaunch(store: SessionSnapshotStore, restorer: SessionRestorer) -> [RestoredPane] {
        guard let snapshot = store.load() else { return [] }
        return restorer.restore(snapshot)
    }

    /// The launch-time restorer: its reopen closure hops back onto the main actor (the
    /// restorer invokes it synchronously during the main-actor `restoreOnLaunch`) and
    /// materializes each re-opened pane as a real board card. The command it receives is
    /// the firewall-classified `$SHELL -il` the restorer built — never an agent.
    private func makeLaunchRestorer() -> SessionRestorer {
        SessionRestorer(reopen: { [weak self] pane, command in
            MainActor.assumeIsolated { self?.openRestoredCard(pane: pane, command: command) }
        })
    }

    /// Launch one restored pane's shell and drop its card on the board — a login shell in
    /// the pane's cwd, launched through the registry (never `claude -p`). `command` is the
    /// firewall-clean `$SHELL -il` the restorer validated, so the watcher-not-spawner
    /// invariant holds; this method builds no agent command of its own.
    private func openRestoredCard(pane: RestoredPane, command: [String]) {
        guard let session = try? registry.launch(
            command: command, projectDir: pane.cwd,
            agentType: .shell, flowTag: pane.snapshot.flowTag
        ) else { return }
        ShellSignalBridge.attachCwdReporting(to: session)   // US-004: live OSC-7 cwd
        // A pane that was driving a Claude conversation comes back on that conversation,
        // not as a bare shell: resume the pinned id we persisted. The restored session
        // carries the ORIGINAL id forward (not its own fresh `id`), so the resume token
        // survives an unbounded chain of restarts. Interactive `claude` only — firewall-clean.
        if let claudeID = Self.claudeResumeID(for: pane.snapshot), pane.liveness == .reopened {
            session.recordClaudeSession(claudeID)
        } else if pane.snapshot.agentType == .codex, pane.liveness == .reopened {
            HookInstaller.installCodexShim()
        }
        if let command = Self.restoredAgentCommand(for: pane.snapshot), pane.liveness == .reopened {
            _ = session.pty.send(Array(command.utf8))
        }
        // Identity and column both come from the snapshot. The id must be the ORIGINAL:
        // the shell we just re-opened exports it as GHOSTLING_CARD_ID, and a fresh UUID
        // here would leave every incoming hook line pointing at a card that doesn't exist,
        // freezing this card in place for the rest of the app's life.
        let card = BoardCard(
            id: pane.snapshot.cardID ?? UUID(),
            sessionID: pane.snapshot.sessionID.uuidString,
            title: pane.snapshot.title, projectDir: pane.cwd,
            agent: Self.cardAgent(for: pane.snapshot.agentType),
            flow: Self.cardFlow(for: pane.snapshot.flowTag),
            state: pane.snapshot.cardState ?? .idle,
            taskFolder: pane.snapshot.taskFolder
        )
        cards.append(card)
        if card.state == .done {
            manuallyDoneCardIDs.insert(card.id)
        }
        ptyByCard[card.id] = session.pty
    }

    /// The keystrokes that start a NEW Claude conversation pinned to `sessionID`, so we
    /// know the id up front and can resume it later. Lowercased to match Claude's own
    /// transcript-id form (what `--resume` looks up).
    static func startClaudeCommand(sessionID: UUID) -> String {
        "claude --session-id \(sessionID.uuidString.lowercased())\n"
    }

    /// The keystrokes that RESUME the conversation `sessionID` on a restored pane. Falls
    /// back to a fresh `claude` if the transcript is gone (resume exits non-zero), so a
    /// restore never lands the operator on a dead shell; stderr is dropped so the expected
    /// "no conversation" note doesn't flash before the fallback.
    static func resumeClaudeCommand(sessionID: UUID) -> String {
        "claude --resume \(sessionID.uuidString.lowercased()) 2>/dev/null || claude\n"
    }

    /// Prefer the explicit pinned Claude conversation id. For snapshots written before
    /// that field existed, a Claude pane's own session id is the best available resume
    /// token: newer create paths pinned Claude to that id, and if no transcript exists
    /// the generated command falls back to fresh interactive `claude`.
    static func claudeResumeID(for pane: PaneSnapshot) -> UUID? {
        pane.claudeSessionID ?? (pane.agentType == .claude ? pane.sessionID : nil)
    }

    static func restoredAgentCommand(for pane: PaneSnapshot) -> String? {
        if let claudeID = claudeResumeID(for: pane) {
            return resumeClaudeCommand(sessionID: claudeID)
        }
        if pane.agentType == .codex {
            return resumeCodexCommand()
        }
        return nil
    }

    /// Start a Codex CLI session in the already-open login shell.
    static func startCodexCommand() -> String {
        "\(HookInstaller.codexShimPath())/codex\n"
    }

    /// Resume the most recent Codex interactive session for this cwd. Codex owns its
    /// saved session ids, so we use its cwd-filtered `--last` behavior instead of
    /// inventing an app-level id.
    static func resumeCodexCommand() -> String {
        "\(HookInstaller.codexShimPath())/codex resume --last\n"
    }

    /// US-004: install Ghostty shell-integration idempotently (a no-op on the second
    /// launch), mirroring ``HookInstaller``. Injectable shell/root/rc so a test drives the
    /// launch path into temp files, never the real `~/.zshrc`. Non-zsh shells and write
    /// failures degrade gracefully — this never crashes launch.
    @discardableResult
    func installShellIntegration(shell: LoginShell = .current, installRoot: URL, rc: URL) -> Bool {
        ShellIntegrationInstaller.install(shell: shell, rc: rc, installRoot: installRoot)
    }

    private static func cardAgent(for type: AgentType) -> CardAgent {
        CardAgent(rawValue: type.rawValue) ?? .claude
    }

    private static func cardFlow(for tag: FlowTag) -> CardFlow {
        tag == .backlog ? .a : .b
    }

    /// Where the bundled shell-integration files live (Application Support), resolved
    /// once. Falls back to the temp dir if Application Support is unavailable.
    private static func shellIntegrationRoot() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Ghostling/shell-integration", isDirectory: true)
    }

    /// The operator's `~/.zshrc` — the rc the integration source line is appended to.
    private static func defaultZshrc() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    /// Build the seeded board hierarchy **without** ordering a window on screen, so
    /// the drill-in interaction (board hidden on drill, restored on return) can be
    /// driven by a headless view-level test. Wires interactions exactly as
    /// `applicationDidFinishLaunching` does — otherwise the back-affordance callback
    /// (`drillIn.onClose → returnToBoard`) is unwired and a test would silently
    /// Test seam: does this card still own a live PTY? Used to prove a delete forgets
    /// its session binding (returns nil after `deleteCard`).
    func ptyForTesting(_ cardID: UUID) -> PTYSession? { ptyByCard[cardID] }

    /// Test seam: restore through the REAL launch-time restorer (the one that rebuilds
    /// cards via `openRestoredCard`), not a spy — so a round-trip test can assert the
    /// restored *cards* (title + task folder came back), not just the raw snapshot.
    /// Returns the rebuilt board cards.
    @discardableResult
    func restoreCardsForTesting(store: SessionSnapshotStore) -> [BoardCard] {
        _ = restoreOnLaunch(store: store, restorer: makeLaunchRestorer())
        return cards
    }

    /// bypass the real Esc/click → return chain. Returns the root content view.
    @discardableResult
    func buildContentForTesting() -> NSView {
        seedSessions()
        let root = makeContentView(in: NSSize(width: 1280, height: 720))
        wireInteractions()
        root.layoutSubtreeIfNeeded()
        return root
    }

    /// Test seam (US-004 AC2): is this PTY session held by the pool-firewalled
    /// registry? Lets a test prove the planning terminal is registered exactly once
    /// through the normal path — no bypass, no second spawn.
    func isRegistered(_ pty: PTYSession) -> Bool {
        registry.all.contains { $0.pty === pty }
    }

    /// Test seam: open Planning Mode on a card through the exact production entry
    /// (attaches the registered pty, hides the board) — the real gesture handlers call
    /// this same method.
    func enterPlanningModeForTesting(_ card: BoardCard) { enterPlanningMode(card) }

    // MARK: - Seeding

    private func seedSessions() {
        for seed in seeds {
            guard let session = launch(seed) else { continue }
            let inferredTaskFolder: String?
            if seed.flow == .a, seed.taskFolder == nil {
                inferredTaskFolder = TaskFolderIndex().inferredFolder(
                    in: URL(fileURLWithPath: seed.projectDir, isDirectory: true)
                )?.path
            } else {
                inferredTaskFolder = seed.taskFolder
            }
            let card = BoardCard(
                id: seed.cardID.flatMap(UUID.init(uuidString:)) ?? UUID(),
                sessionID: seed.sessionID, title: seed.title, projectDir: seed.projectDir,
                agent: seed.agent, flow: seed.flow, state: seed.state,
                taskFolder: inferredTaskFolder
            )
            cards.append(card)
            ptyByCard[card.id] = session.pty
        }
    }

    private func launch(_ seed: BoardSeed) -> Session? {
        if let launchOverrideForTesting {
            return launchOverrideForTesting(seed)
        }
        guard let session = try? registry.launch(
            command: seed.command,
            projectDir: seed.projectDir,
            agentType: AgentType(rawValue: seed.agent.rawValue) ?? .shell,
            flowTag: seed.flow == .a ? .backlog : .interactive
        ) else { return nil }
        ShellSignalBridge.attachCwdReporting(to: session)   // US-004: live OSC-7 cwd
        return session
    }

    // MARK: - Window

    /// A minimal main menu so ⌘N opens the create palette (the design's shortcut) and
    /// ⌘Q quits — `swift run` binaries start with no menu at all. ponytail: two items,
    /// no nib; grows only if more shortcuts are actually wanted.
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "New Task", action: #selector(newTaskMenuAction),
                        keyEquivalent: "n").target = self
        let remote = appMenu.addItem(withTitle: "New Remote tmux Session…",
                                     action: #selector(newRemoteTmuxMenuAction), keyEquivalent: "r")
        remote.keyEquivalentModifierMask = [.command, .shift]
        remote.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Increase Board Font",
                        action: #selector(increaseBoardFontMenuAction),
                        keyEquivalent: "=").target = self
        appMenu.addItem(withTitle: "Decrease Board Font",
                        action: #selector(decreaseBoardFontMenuAction),
                        keyEquivalent: "-").target = self
        let terminalUp = appMenu.addItem(withTitle: "Increase Terminal Font",
                                         action: #selector(increaseTerminalFontMenuAction),
                                         keyEquivalent: "+")
        terminalUp.keyEquivalentModifierMask = [.command, .shift]
        terminalUp.target = self
        let terminalDown = appMenu.addItem(withTitle: "Decrease Terminal Font",
                                           action: #selector(decreaseTerminalFontMenuAction),
                                           keyEquivalent: "_")
        terminalDown.keyEquivalentModifierMask = [.command, .shift]
        terminalDown.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ghostling", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let main = NSMenu()
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    @objc private func newTaskMenuAction() { openCreatePalette() }
    @objc private func increaseBoardFontMenuAction() { changeBoardFont(by: 0.1) }
    @objc private func decreaseBoardFontMenuAction() { changeBoardFont(by: -0.1) }
    @objc private func increaseTerminalFontMenuAction() { changeTerminalFont(by: 1) }
    @objc private func decreaseTerminalFontMenuAction() { changeTerminalFont(by: -1) }

    /// Prompt for a remote destination + tmux session, then open the card. Kept thin:
    /// destination parsing lives in `RemoteTmuxSpec.parse` and card creation in
    /// `createRemoteTmuxSession`, both unit-tested; this only collects the strings.
    @objc private func newRemoteTmuxMenuAction() {
        guard let (destination, session, dir) = promptRemoteTmux() else { return }
        guard let spec = RemoteTmuxSpec.parse(
            destination: destination, sessionName: session, remoteDir: dir) else { return }
        _ = createRemoteTmuxSession(spec: spec)
    }

    /// A 3-field sheet (destination `[user@]host[:port]`, tmux session, optional start
    /// dir). Returns nil on cancel or a blank destination.
    private func promptRemoteTmux() -> (destination: String, session: String, dir: String)? {
        let alert = NSAlert()
        alert.messageText = "New remote tmux session"
        alert.informativeText = "Attach to (or create) a tmux session over SSH."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let (view, fields) = remoteTmuxAccessory()
        alert.accessoryView = view
        alert.window.initialFirstResponder = fields.destination
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let destination = fields.destination.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return nil }
        let session = fields.session.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (destination, session.isEmpty ? "ghostling" : session,
                fields.dir.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func remoteTmuxAccessory()
        -> (NSView, (destination: NSTextField, session: NSTextField, dir: NSTextField)) {
        let destination = remoteField(placeholder: "user@host  or  host:2222")
        let session = remoteField(placeholder: "ghostling")
        let dir = remoteField(placeholder: "start dir (optional)")
        let rows = [labeledRow("Destination", destination),
                    labeledRow("tmux session", session),
                    labeledRow("Start dir", dir)]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 96)
        return (stack, (destination, session, dir))
    }

    private func remoteField(placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return f
    }

    private func labeledRow(_ label: String, _ field: NSTextField) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 11)
        l.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [l, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    /// Disk-writing installs + the notification prompt, run one tick after launch so
    /// they never block the window's first paint. All are idempotent and degrade
    /// gracefully, so deferring them changes only *when* they run, not *whether*.
    private func installPostLaunchIntegrations() {
        SystemNotifier.requestAuthorization()
        // Clean up old global Ghostling Claude hooks from prior builds; status is now
        // scoped through managed PATH shims below, so global config would duplicate and
        // cross-contaminate unrelated Claude sessions.
        HookInstaller.uninstallGlobal()
        // Managed PATH shims inject hooks per invocation, cmux-style. This keeps
        // Claude/Codex status scoped to Ghostling-owned terminals instead of mutating
        // global agent config and cross-contaminating unrelated sessions.
        HookInstaller.installClaudeShim()
        HookInstaller.installCodexShim()
        // US-004: install Ghostty shell-integration the same way (idempotent; non-zsh
        // and write failures degrade gracefully) so the shell reports cwd semantically.
        installShellIntegration(installRoot: Self.shellIntegrationRoot(), rc: Self.defaultZshrc())
    }

    /// Ctrl+Tab / Ctrl+Shift+Tab jumps straight between focused tasks. A local key
    /// monitor is the single choke point that fires BEFORE the drilled-in terminal's
    /// first responder swallows the key — unlike ⌘-combos, a Control-modified key isn't
    /// reliably routed through `performKeyEquivalent`, and plain Tab belongs to the
    /// child. Works identically from the board, drill-in, and planning mode.
    private func installTaskSwitchMonitor() {
        taskSwitchMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let reverse = Self.switchDirection(for: event) else { return event }
            self.cycleDrill(reverse: reverse)
            return nil   // consume it — never let plain Tab reach the child
        }
    }

    /// Decode a key event into a switch direction (`false` = next, `true` = previous),
    /// or `nil` when it isn't the switch chord. Static + `NSEvent`-driven so a test can
    /// dispatch a REAL Ctrl+Tab event through the same decode the monitor uses, per the
    /// Interaction-AC Binding Rule — not by calling a handler.
    static func switchDirection(for event: NSEvent) -> Bool? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // keyCode 48 = Tab. Control required; Command must be absent (⌘Tab is the OS
        // app-switcher, not ours); Shift reverses.
        guard event.keyCode == 48, flags.contains(.control), !flags.contains(.command)
        else { return nil }
        return flags.contains(.shift)
    }

    private func makeWindow() {
        let window = NSWindow(
            // 1400×860: wide enough that all 5 columns + the quota panel fit on
            // launch, yet still fits a 1440-wide laptop screen after .center().
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Ghostling — mission control"
        // Dissolve the stock grey title bar into the app's dark chrome: transparent bar
        // filled with the canvas colour, no centred title text — leaves just the traffic
        // lights over one continuous surface. (No fullSizeContentView: content still lays
        // out below the bar, so nothing collides with the traffic lights.)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = BoardTheme.canvas
        // Follow the system appearance (nil) rather than pinning `.darkAqua`. Every
        // surface is painted from `BoardTheme`'s dynamic light/dark tokens, so pinning
        // dark froze `effectiveAppearance` and stopped those tokens — and the terminal
        // surface, whose live-flip hook keys off appearance changes — from ever
        // resolving light. Following the system flips the whole app, terminal included.
        window.appearance = nil
        // The fixed 5-column board clips below ~1360pt with no scroll signal
        // (ColumnLayout's known ceiling) — stop the window from shrinking into it.
        window.contentMinSize = NSSize(width: 1360, height: 640)
        window.contentView = makeContentView(in: window.frame.size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(boardView)   // arrow-key board navigation from launch
        self.window = window
    }

    private func makeContentView(in size: NSSize) -> NSView {
        // A `ThemedRootView`, not a plain NSView: it owns the single appearance hook the
        // whole window hangs off, re-resolving every `themedBackground`/`themedBorder`
        // beneath it on a light/dark flip. Layer fills snapshot their colour when set, so
        // without this the board would flip and the drill-in and quota panel would not.
        let root = ThemedRootView(frame: NSRect(origin: .zero, size: size))
        root.themedBackground = BoardTheme.canvas
        // Follow the system appearance (don't pin `.darkAqua`): the UI is painted from
        // `BoardTheme`'s dynamic light/dark tokens, and standard control chrome should
        // match the active system theme so the app reads light in light mode.
        layout(attention, in: root, header: true)
        layoutFontControls(in: root)
        layoutQuota(in: root)
        layout(boardView, in: root, header: false)
        drillIn.isHidden = true
        layoutDrillIn(in: root)
        planningMode.isHidden = true
        layoutFullWindow(planningMode, in: root)
        return root
    }

    private func layoutFullWindow(_ view: NSView, in root: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            view.topAnchor.constraint(equalTo: root.topAnchor),
            view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    /// The quota panel pinned to the trailing edge as a fixed-width column, from
    /// just under the header to the bottom — the board fills the remaining width.
    private func layoutQuota(in root: NSView) {
        quota.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(quota)
        NSLayoutConstraint.activate([
            quota.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            quota.topAnchor.constraint(equalTo: root.topAnchor, constant: 32),
            quota.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            quota.widthAnchor.constraint(equalToConstant: 340),
        ])
    }

    private func layoutFontControls(in root: NSView) {
        fontControls.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(fontControls)
        NSLayoutConstraint.activate([
            fontControls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            fontControls.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            fontControls.heightAnchor.constraint(equalToConstant: 30),
            fontControls.widthAnchor.constraint(equalToConstant: fontControls.intrinsicContentSize.width),
        ])
    }

    private func layout(_ view: NSView, in root: NSView, header: Bool) {
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate(header
            ? headerConstraints(view, in: root)
            : boardConstraints(view, in: root))
    }

    private func headerConstraints(_ v: NSView, in root: NSView) -> [NSLayoutConstraint] {
        [
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            v.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            v.heightAnchor.constraint(equalToConstant: 26),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ]
    }

    private func boardConstraints(_ v: NSView, in root: NSView) -> [NSLayoutConstraint] {
        [
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            // Board fills the width left of the quota column (not the full root).
            v.trailingAnchor.constraint(equalTo: quota.leadingAnchor, constant: -12),
            v.topAnchor.constraint(equalTo: root.topAnchor, constant: 32),
            v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
    }

    /// US-002: the drill-in is a full-window terminal takeover (Altitude-1) — it
    /// fills the entire root, not a side panel, so nothing of the board shows
    /// behind the opaque terminal.
    private func layoutDrillIn(in root: NSView) {
        drillIn.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(drillIn)
        NSLayoutConstraint.activate([
            drillIn.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            drillIn.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            drillIn.topAnchor.constraint(equalTo: root.topAnchor),
            drillIn.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    // MARK: - Interactions

    private func wireInteractions() {
        boardView.onSelect = { [weak self] in self?.drill(into: $0) }
        boardView.onCreate = { [weak self] in self?.promptAndCreateSession() }
        boardView.onMove = { [weak self] id, column in self?.move(cardID: id, to: column) }
        boardView.onRename = { [weak self] in self?.promptRename(for: $0) }
        boardView.onDelete = { [weak self] in self?.promptDelete(for: $0) }
        attention.onActivate = { [weak self] in self?.activateAttention() }
        fontControls.onBoardSmaller = { [weak self] in self?.changeBoardFont(by: -0.1) }
        fontControls.onBoardLarger = { [weak self] in self?.changeBoardFont(by: 0.1) }
        drillIn.onTerminalSmaller = { [weak self] in self?.changeTerminalFont(by: -1) }
        drillIn.onTerminalLarger = { [weak self] in self?.changeTerminalFont(by: 1) }
        planningMode.onTerminalSmaller = { [weak self] in self?.changeTerminalFont(by: -1) }
        planningMode.onTerminalLarger = { [weak self] in self?.changeTerminalFont(by: 1) }
        drillIn.onClose = { [weak self] in self?.returnToBoard() }
        planningMode.onReturn = { [weak self] in self?.returnToBoard() }
    }

    private func changeBoardFont(by delta: CGFloat) {
        BoardTheme.boardFontScale = min(1.8, max(1.0, BoardTheme.boardFontScale + delta))
        boardView.applyFontScale()
        attention.update(count: attention.renderedCount)
        quota.render(gauges: QuotaProjection.gauges(from: quotaSources))
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func changeTerminalFont(by delta: CGFloat) {
        terminalFontSize = min(28, max(12, terminalFontSize + delta))
        drillIn.updateTerminalFontSize(terminalFontSize)
        planningMode.updateTerminalFontSize(terminalFontSize)
    }

    /// The "+ new session" affordance (⌘N): open the keyboard-first create palette —
    /// project → harness → task — replacing the old NSAlert + bare chooser. A card is a
    /// *task* the operator is working on, not an anonymous `terminal-N`; naming it at
    /// birth is what makes the board legible. Cancelling creates nothing.
    func promptAndCreateSession() { openCreatePalette() }

    /// Mount ``CreateCardPalette`` full-window and wire its confirm closures to the
    /// card-creation logic (which owns the pool firewall + saha binding invariants).
    /// The palette is a dumb view; every side effect flows back through here.
    func openCreatePalette() {
        let palette = CreateCardPalette(recents: paletteRecents())
        palette.browse = { [weak self] in Self.chooseFolder(relativeTo: self?.window) }
        palette.discoverFolders = { dir in
            TaskFolderIndex().discover(in: URL(fileURLWithPath: dir, isDirectory: true))
        }
        palette.onCancel = { [weak self] in self?.dismissCreatePalette() }
        palette.confirmInteractive = { [weak self] title, dir, harness, inWorktree in
            guard let self else { return }
            self.createSession(title: title.isEmpty ? nil : title, projectDir: dir,
                               autoStartAgent: harness.cardAgent, inWorktree: inWorktree)
            self.rememberProjectDir(dir)
            self.dismissCreatePalette()
        }
        palette.confirmSahaNew = { [weak self] title, dir in
            self?.completeSahaNew(title: title, dir: dir)
        }
        palette.confirmSahaExisting = { [weak self] folder, dir in
            self?.completeSahaExisting(folder: folder, dir: dir)
        }
        createPalette?.removeFromSuperview()
        createPalette = palette
        guard let root = boardView.superview else { return }
        layoutFullWindow(palette, in: root)
        window?.makeFirstResponder(palette)
    }

    /// saha "Create new" from the palette: scaffold + bind + enter planning. Returns an
    /// error string for the palette to show, or nil on success (planning is now up).
    private func completeSahaNew(title: String, dir: String) -> String? {
        do {
            guard let card = try createSahaSession(
                title: title,
                projectDirectory: URL(fileURLWithPath: dir, isDirectory: true),
                script: sahaInitScript(),
                scaffolder: TaskScaffolder(runner: FoundationTaskScaffoldRunner())
            ) else { return "Could not launch the planning terminal." }
            rememberProjectDir(dir)
            dismissCreatePalette()
            _ = card
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// saha "bind existing folder" from the palette: bind + enter planning.
    private func completeSahaExisting(folder: URL, dir: String) -> String? {
        guard let card = createSahaExisting(
            folder: folder, projectDirectory: URL(fileURLWithPath: dir, isDirectory: true)
        ) else { return "Could not launch the planning terminal." }
        rememberProjectDir(dir)
        dismissCreatePalette()
        _ = card
        return nil
    }

    func dismissCreatePalette() {
        createPalette?.removeFromSuperview()
        createPalette = nil
        window?.makeFirstResponder(boardView)
    }

    /// Recent project dirs as palette rows, each tagged with how many owned (live-pty)
    /// cards currently run in it — the "N active cards" the design shows.
    private func paletteRecents() -> [PaletteProject] {
        var active: [String: Int] = [:]
        for card in cards where ptyByCard[card.id] != nil {
            active[Self.normDir(card.projectDir), default: 0] += 1
        }
        return recentProjectDirs().map {
            PaletteProject(path: $0, activeCards: active[Self.normDir($0)] ?? 0)
        }
    }

    /// Fixture folders so a capture of the task stage shows the full bind-list (progress
    /// bars + "Create new") even in a repo with no `docs/tasks`. Capture-seam only.
    private static func demoTaskFolders(_ dir: String) -> [TaskFolderSummary] {
        let base = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("docs/tasks")
        return [
            TaskFolderSummary(url: base.appendingPathComponent("task-08-native-saha-planning"),
                              title: "task-08-native-saha-planning", progress: .known(completed: 6, total: 8)),
            TaskFolderSummary(url: base.appendingPathComponent("task-05-turn-diffs"),
                              title: "task-05-turn-diffs", progress: .known(completed: 4, total: 4)),
        ]
    }

    /// The bundled task-folder scaffolder (`.claude/scripts/init_task.sh`), resolved
    /// relative to the repo root. ponytail: one known script path, no lookup config.
    private func sahaInitScript() -> URL {
        let base = repoRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.appendingPathComponent(".claude/scripts/init_task.sh")
    }

    /// The native macOS folder chooser, run as a nested modal over the palette.
    /// ponytail: nested modal is fine for a one-shot picker; AppKit stacks them.
    private static func chooseFolder(relativeTo window: NSWindow?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        panel.message = "Choose the project folder for this task"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Recently-used project dirs, most-recent first, with the repo root guaranteed
    /// present as a fallback. Persisted in UserDefaults so the list survives relaunch.
    private func recentProjectDirs() -> [String] {
        let root = repoRoot?.path ?? FileManager.default.currentDirectoryPath
        var dirs = UserDefaults.standard.stringArray(forKey: Self.recentDirsKey) ?? []
        if !dirs.contains(root) { dirs.append(root) }
        return dirs
    }

    /// Push a dir to the front of the MRU list (deduped, capped at 6). ponytail:
    /// UserDefaults is the stdlib MRU store — no file/db for six strings.
    private func rememberProjectDir(_ dir: String) {
        let expanded = (dir as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return }
        var dirs = UserDefaults.standard.stringArray(forKey: Self.recentDirsKey) ?? []
        dirs.removeAll { $0 == expanded }
        dirs.insert(expanded, at: 0)
        UserDefaults.standard.set(Array(dirs.prefix(6)), forKey: Self.recentDirsKey)
    }

    private static let recentDirsKey = "ghostling.recentProjectDirs"

    /// US-003: launch a fresh REAL interactive terminal card (your login shell in the
    /// chosen folder; drill in and run `claude`) under the given task title and drop
    /// it on the board. Firewall-clean: a login shell, never `claude -p`. The model
    /// mutation is split from the prompt so a test can drive it without a modal.
    @discardableResult
    func createSession(
        title: String? = nil,
        projectDir: String? = nil,
        startClaude: Bool = false,
        autoStartAgent: CardAgent? = nil,
        flow: CardFlow = .b,
        taskFolder: String? = nil,
        inWorktree: Bool = false
    ) -> BoardCard? {
        sessionCounter += 1
        let chosen = (projectDir?.isEmpty == false) ? projectDir : nil
        var dir = chosen.map { ($0 as NSString).expandingTildeInPath }
            ?? repoRoot?.path ?? FileManager.default.currentDirectoryPath
        if inWorktree,
           let worktree = worktreeProvisioner.provision(repoDir: dir, slug: sessionSlug(title)) {
            // The card LIVES in its own checkout on a fresh task/<slug> branch, so
            // parallel tasks on one repo stop stepping on each other's working tree.
            // A non-repo dir (or git failure) falls through to the chosen dir — the
            // worktree is an upgrade, never a gate on creating the card.
            dir = worktree.path
        }
        // The card id is minted BEFORE launch so it can ride the pty environment
        // (GHOSTLING_CARD_ID) — the identity binding that folds the hook-observed
        // claude session back into this card even when the repo dir is shared.
        let cardID = UUID()
        let agent = autoStartAgent ?? .claude
        let seed = BoardSeed.liveTerminal(
            projectDir: dir, sessionID: sessionSlug(title), title: title,
            cardID: cardID.uuidString, agent: agent
        )
        guard let session = launch(seed) else { return nil }
        let card = BoardCard(
            id: cardID,
            sessionID: seed.sessionID, title: seed.title, projectDir: seed.projectDir,
            agent: seed.agent, flow: flow, state: seed.state,
            taskFolder: taskFolder
        )
        cards.append(card)
        ptyByCard[card.id] = session.pty
        if startClaude || autoStartAgent == .claude {
            // Type the start-claude line into the fresh login shell for the operator — the
            // tty input buffer holds it until the shell finishes initialising. Interactive
            // pool only; the firewall against `claude -p` is untouched.
            //
            // We OWN the conversation id: pin claude to our session UUID with `--session-id`
            // rather than let it mint its own. That id is then persisted per pane (see
            // `snapshotWindows`), so on the next app launch `openRestoredCard` resumes the
            // exact conversation — no hook-log scraping, and correct even when several task
            // cards share one repo dir. `--session-id` is fresh here (this UUID has no prior
            // transcript), so claude accepts it.
            session.recordClaudeSession(session.id)
            _ = session.pty.send(Array(Self.startClaudeCommand(sessionID: session.id).utf8))
        } else if autoStartAgent == .codex {
            HookInstaller.installCodexShim()
            _ = session.pty.send(Array(Self.startCodexCommand().utf8))
        }
        refresh()
        return card
    }

    /// Open a REMOTE terminal card: SSH into `spec.host` and attach to (or create) a
    /// tmux session there. Mirrors ``createSession`` but skips the local-only steps
    /// (worktree, cwd reporting, auto-`claude`) — a remote card has no local checkout,
    /// and the human drives the far-side session themselves. Firewall-clean (the launched
    /// binary is `ssh`). The model mutation is split from any prompt so tests can drive it.
    @discardableResult
    func createRemoteTmuxSession(spec: RemoteTmuxSpec) -> BoardCard? {
        sessionCounter += 1
        let cardID = UUID()
        guard let seed = try? BoardSeed.remoteTmux(spec: spec, cardID: cardID.uuidString),
              let session = launch(seed) else { return nil }
        let card = BoardCard(
            id: cardID,
            sessionID: seed.sessionID, title: seed.title, projectDir: seed.projectDir,
            agent: seed.agent, flow: seed.flow, state: seed.state
        )
        cards.append(card)
        ptyByCard[card.id] = session.pty
        refresh()
        return card
    }

    @discardableResult
    func createSahaSession(
        title: String,
        projectDirectory: URL,
        script: URL,
        scaffolder: any TaskFolderScaffolding
    ) throws -> BoardCard? {
        let taskFolder = try scaffolder.create(
            title: title, projectDirectory: projectDirectory, script: script
        )
        guard let card = createSession(
            title: title,
            projectDir: projectDirectory.path,
            startClaude: true,   // saha steps are Claude Code slash-commands — they need claude, not a bare shell
            flow: .a,
            taskFolder: taskFolder.path
        ) else { return nil }
        enterPlanningMode(card)
        return card
    }

    /// Bind a saha card to an ALREADY-scaffolded task folder (the "existing folder"
    /// path) and drop straight into planning. Shared by the create palette and the
    /// legacy chooser so the flow-.a binding invariants live in one place.
    @discardableResult
    func createSahaExisting(folder: URL, projectDirectory: URL) -> BoardCard? {
        guard let card = createSession(
            title: folder.lastPathComponent,
            projectDir: projectDirectory.path,
            startClaude: true,   // saha steps are Claude Code slash-commands — they need claude, not a bare shell
            flow: .a,
            taskFolder: folder.path
        ) else { return nil }
        enterPlanningMode(card)
        return card
    }

    /// Presents the real saha folder chooser and wires both choices to card
    /// insertion. A failed scaffold or terminal launch leaves the board unchanged.
    /// ponytail: retained as the invariant harness for the saha binding rules
    /// (TC-E2E-001b et al.); the production create entry is ``CreateCardPalette``.
    func beginSahaCreation(
        projectDirectory: URL,
        script: URL,
        scaffolder: any TaskFolderScaffolding
    ) {
        let folders = TaskFolderIndex().discover(in: projectDirectory)
        let chooser = SahaTaskChooserView(folders: folders)
        chooser.bindFolderURLs(folders)
        chooser.onChooseExisting = { [weak self, weak chooser] folder in
            guard let self else { return }
            guard let card = self.createSahaExisting(folder: folder, projectDirectory: projectDirectory) else {
                chooser?.show(error: "Could not launch the planning terminal.")
                return
            }
            chooser?.removeFromSuperview()
            self.sahaTaskChooser = nil
            _ = card
        }
        chooser.onCreateNew = { [weak self, weak chooser] title in
            guard let self else { return }
            do {
                guard let card = try self.createSahaSession(
                    title: title,
                    projectDirectory: projectDirectory,
                    script: script,
                    scaffolder: scaffolder
                ) else {
                    chooser?.show(error: "Could not launch the planning terminal.")
                    return
                }
                chooser?.removeFromSuperview()
                self.sahaTaskChooser = nil
                self.enterPlanningMode(card)
            } catch {
                chooser?.show(error: error.localizedDescription)
            }
        }
        sahaTaskChooser?.removeFromSuperview()
        sahaTaskChooser = chooser
        guard let root = boardView.superview else { return }
        layoutFullWindow(chooser, in: root)
    }

    private func enterPlanningMode(_ card: BoardCard) {
        planningModeCardID = card.id
        boardView.isHidden = true
        attention.isHidden = true
        fontControls.isHidden = true
        quota.isHidden = true
        drillIn.isHidden = true
        planningMode.show(card: card)
        // Mount the card's already-registered interactive session as the planning
        // terminal (US-004 AC2) — reused, never a new spawn. Its surface now owns the
        // fd, so the background pump must skip it (one reader per fd).
        if let pty = ptyByCard[card.id] {
            planningMode.attach(session: pty, terminalFontSize: terminalFontSize)
        }
        planningMode.isHidden = false
        if let surface = planningMode.terminalSurface {
            window?.makeFirstResponder(surface)
        }
    }

    /// A stable, readable session id derived from the task title ("Fix login" →
    /// `fix-login`) so the card's identifier line means something instead of a bare
    /// `terminal-N`. Falls back to the counter when there's no usable title.
    /// ponytail: no collision suffix — the card's UUID is the real identity; two
    /// same-titled cards just share a label.
    private func sessionSlug(_ title: String?) -> String {
        let slug = (title ?? "").lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" && acc.last == "-" { return }   // collapse runs
                acc.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "terminal-\(sessionCounter)" : slug
    }

    /// A card was dragged to another column → set its state to that column's state
    /// (a manual lifecycle override). Identity and PTY are preserved, so a drilled-in
    /// terminal keeps working; only the state — hence the board column — changes.
    func move(cardID: UUID, to column: BoardColumn) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        let previousState = cards[idx].state
        cards[idx] = cards[idx].with(state: column.state)
        if column == .done {
            manuallyDoneCardIDs.insert(cardID)
            manuallyReopenedDoneCardIDs.remove(cardID)
        } else {
            if previousState == .done {
                manuallyReopenedDoneCardIDs.insert(cardID)
            }
            manuallyDoneCardIDs.remove(cardID)
        }
        refresh()
    }

    /// Rename a card in place — identity, state, and PTY binding all preserved (the
    /// mutator keeps `id`), so renaming a live task never disturbs its session. An
    /// empty title clears back to the project-dir fallback.
    func rename(cardID: UUID, to newTitle: String?) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[idx] = cards[idx].with(title: newTitle)
        refresh()
    }

    /// The "Rename Task…" context-menu prompt: a modal sheet-style alert with the
    /// current title pre-filled and selected, so a quick type-over just works.
    private func promptRename(for card: BoardCard) {
        let alert = NSAlert()
        alert.messageText = "Rename Task"
        alert.informativeText = "A blank name falls back to the project folder."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = card.title ?? ""
        field.placeholderString = BoardTheme.shortPath(card.projectDir)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rename(cardID: card.id, to: field.stringValue)
    }

    /// The "Delete Task…" context-menu prompt: a destructive confirmation that
    /// names what will be torn down (the session, and — when the card lives in its
    /// own git worktree — that checkout too). The worktree note only appears when
    /// there's actually one to clean, so the copy never lies.
    private func promptDelete(for card: BoardCard) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(card.title ?? BoardTheme.shortPath(card.projectDir))?"
        let path = (card.projectDir as NSString).expandingTildeInPath
        alert.informativeText = GitWorktree.isWorktree(path)
            ? "This ends the session and removes its git worktree checkout (\(BoardTheme.shortPath(path))). Uncommitted changes on that branch are lost."
            : "This ends the session and removes the task from the board."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        // The destructive button is default-styled; make Cancel the safe Return key.
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteCard(cardID: card.id)
    }

    /// Tear a task fully down (US: "ability to delete task, clean worktree too"):
    /// leave the drill-in if it's the focused card, kill its live session, remove its
    /// git worktree when it has one, drop the card, and forget all per-card bookkeeping
    /// so nothing dangles. Persists the trimmed session tree so the deletion survives a
    /// relaunch. Safe to call for an observed (PTY-less) card too.
    func deleteCard(cardID: UUID) {
        guard let card = cards.first(where: { $0.id == cardID }) else { return }
        if drilledInCardID == cardID { returnToBoard() }
        let pty = ptyByCard.removeValue(forKey: cardID)
        pty?.terminate()
        // Drop the registry entry too, or the persisted session tree would restore
        // the deleted task on the next launch (snapshotWindows walks the registry).
        if let pty, let dead = registry.all.first(where: { $0.pty === pty }) {
            registry.remove(id: dead.id)
        }
        _ = worktreeProvisioner.remove(worktreeAt: (card.projectDir as NSString).expandingTildeInPath)
        cards.removeAll { $0.id == cardID }
        deadCardIDs.remove(cardID)
        idleHoldUntil.removeValue(forKey: cardID)
        lastCardStates.removeValue(forKey: cardID)
        refresh()
        persistOnTerminate(store: SessionSnapshotStore.applicationSupport())
    }

    /// US-002: drill into a card → full-window terminal takeover (Altitude-1).
    /// The board surface and attention header are hidden so the embedded terminal
    /// is the only thing on screen.
    func drill(into card: BoardCard) {
        guard let pty = ptyByCard[card.id] else { return }
        // A saha planning card re-opens the planning cockpit it was born in, not the
        // bare terminal takeover — otherwise leaving planning mode strands the operator
        // on the board with no way back into the pipeline/review (the "can't re-enter" bug).
        if card.flow == .a, card.taskFolder != nil {
            enterPlanningMode(card)
            return
        }
        selection.focus(card.id)
        drilledInCardID = card.id   // its surface owns the fd now; the pump skips it
        boardView.isHidden = true
        attention.isHidden = true
        fontControls.isHidden = true
        quota.isHidden = true
        drillIn.isHidden = false
        drillIn.focus(card: card, pty: pty, terminalFontSize: terminalFontSize)
        drillIn.update(diffs: turnDiffs)
        drillIn.updateQuota(QuotaProjection.gauges(from: quotaSources))
    }

    /// US-002 AC#2: return to the board, state preserved — un-hide the board and
    /// attention header so the board looks exactly as it did before drilling in.
    func returnToBoard() {
        selection.returnToBoard()
        // A card whose child died while drilled in was left up so the operator could
        // read the end banner; leaving it now is the moment it comes off the board.
        if let dead = drilledInCardID, deadCardIDs.contains(dead) { removeDeadCard(dead) }
        drilledInCardID = nil   // surface is detaching; the pump resumes draining this fd
        boardView.isHidden = false
        attention.isHidden = false
        fontControls.isHidden = false
        quota.isHidden = false
        drillIn.isHidden = true
        // Release the planning terminal's view (the pump resumes draining its fd) but
        // keep the session registered, same as drill-in (TC-E2E-014).
        planningMode.detachSurface()
        planningMode.isHidden = true
        planningModeCardID = nil
        refresh()
        window?.makeFirstResponder(boardView)   // keyboard nav resumes on the board
    }

    /// Ctrl+Tab: jump from the focused task straight to the next drillable one WITHOUT
    /// bouncing off the board — the whole point is to skip "quit to board → open next".
    /// Cycles owned cards in board order (Ctrl+Shift+Tab reverses), wrapping around. A
    /// no-op with fewer than two candidates. From the board (nothing focused) it drills
    /// into the first/last card, so the chord also works as "jump into a task".
    func cycleDrill(reverse: Bool) {
        let drillable = cards.filter { ptyByCard[$0.id] != nil }
        let current = drilledInCardID ?? planningModeCardID
        guard let target = Self.nextCard(in: drillable, after: current, reverse: reverse),
              target.id != current else { return }
        // Hand the target a clean single-reader slate: detach whichever focus surface is
        // live now (drill-in OR planning) so a cross-mode switch never strands a second
        // off-screen reader on one fd or a stale *ModeCardID. `drill(into:)` rebuilds
        // the target's own surface; the pump resumes draining the card we just left.
        teardownFocusForSwitch()
        drill(into: target)
    }

    /// The next card to focus when cycling `after` the current one. From the board
    /// (`current == nil`) that's the first (or last, reversed) card; otherwise it steps
    /// one position with wraparound. Static + pure so the ordering is unit-testable.
    static func nextCard(in cards: [BoardCard], after current: UUID?, reverse: Bool) -> BoardCard? {
        guard !cards.isEmpty else { return nil }
        guard let current, let idx = cards.firstIndex(where: { $0.id == current }) else {
            return reverse ? cards.last : cards.first
        }
        let step = reverse ? -1 : 1
        return cards[(idx + step + cards.count) % cards.count]
    }

    /// Detach the live focus surface (drill-in and/or planning) without un-hiding the
    /// board, so a Ctrl+Tab switch flows one task straight into the next. Idempotent.
    private func teardownFocusForSwitch() {
        drillIn.detachSurface()
        drilledInCardID = nil
        planningMode.detachSurface()
        planningMode.isHidden = true
        planningModeCardID = nil
    }

    /// US-005 AC#2: activating the indicator filters the board to waiting/blocked.
    private func activateAttention() {
        if selection.attentionFilterActive {
            selection.clearAttentionFilter()
        } else {
            selection.activateAttention(cards)
        }
        refresh()
    }

    /// Re-derive the view from the current model — the single render path, so a
    /// live state change just re-runs this (US-003 AC#3 / US-005 live update).
    private func refresh() {
        let count = Attention.count(cards)
        attention.update(count: count)
        alertIfAttentionRose(to: count)
        notifyNewlyDone()
        boardView.render(cards: selection.visibleCards(from: cards))
        quota.render(gauges: QuotaProjection.gauges(from: quotaSources))
        // Keep the drill-in's status pill / waiting banner tracking the live state.
        if let id = drilledInCardID, let card = cards.first(where: { $0.id == id }) {
            drillIn.update(state: card.state)
        }
    }

    /// Fire a "task done" OS notification on the rising edge into `.done` — the
    /// moment an agent finishes, so the operator can look away and be pulled back.
    /// Edge-triggered off `lastCardStates` so it fires once per completion, not on
    /// every 3s refresh while the card sits in DONE. Always notifies (unlike the
    /// attention nudge) — "it's finished" is worth surfacing even while focused,
    /// but only when the app isn't the frontmost window.
    private func notifyNewlyDone() {
        for card in cards {
            let previous = lastCardStates[card.id]
            lastCardStates[card.id] = card.state
            guard card.state == .done, previous != nil, previous != .done else { continue }
            guard !NSApp.isActive else { continue }
            SystemNotifier.notifyDone(taskName: card.title ?? BoardTheme.shortPath(card.projectDir))
        }
        // Drop states for cards that no longer exist so the map can't grow unbounded.
        let live = Set(cards.map(\.id))
        lastCardStates = lastCardStates.filter { live.contains($0.key) }
    }

    /// OS-level nudge when a session newly starts waiting on the operator while
    /// they are in another app. In-app the header indicator already covers it, so
    /// banners stay quiet when active.
    private func alertIfAttentionRose(to count: Int) {
        defer { lastAttentionCount = count }
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : ""
        guard count > lastAttentionCount, !NSApp.isActive else { return }
        SystemNotifier.notifyAttention(count: count)
    }

    /// Swap in fresh quota readings (the Phase-2 live poller calls this) and
    /// re-render through the single path. Kept here so the data source is the
    /// shell's concern, not the panel's.
    func applyQuota(sources: [QuotaSourceInput]) {
        quotaSources = sources
        let gauges = QuotaProjection.gauges(from: quotaSources)
        quota.render(gauges: gauges)
        drillIn.updateQuota(gauges)   // keep the drill-in header readout live too
    }

    /// Merge the live observed-session snapshot onto the board (the event-file tail
    /// poller calls this every 3s).
    ///
    /// Two kinds of card coexist: **owned** cards we launched in our own PTY (the
    /// live interactive terminal — drillable, you run `claude` in it) and
    /// **observed** cards from hook lines in the event file (sessions in other
    /// terminals we watch but never spawned — status-only, no PTY).
    ///
    /// An owned terminal **moves with the agent running inside it**: when you run
    /// `claude` in it, claude POSTs hooks under ITS OWN `session_id` (≠ our
    /// "terminal-N" id) but the SAME project dir, so the owned card ADOPTS that
    /// session's detected state (idle → running → waiting → done) and slides between
    /// columns as the model works — instead of one physical terminal showing up as a
    /// second, drifting card. Identity, title, and PTY are untouched, so a drilled-in
    /// terminal keeps working; only the column changes. Observed sessions we never
    /// spawned are merged in as status-only cards. Re-renders only on a real change,
    /// and never yanks the board out from under an active drill-in.
    func applySessions(_ observed: [BoardCard]) {
        let owned = cards.filter { ptyByCard[$0.id] != nil }
        // Dirs occupied by EXACTLY ONE owned card. Only there is "the agent in this dir
        // is THIS card's agent" a safe inference; a repo dir shared by several task
        // cards is ambiguous — cwd can't say which task an observed session belongs to,
        // so the dir join must NOT fire (else every task in the repo moves at once).
        var dirCount: [String: Int] = [:]
        for card in owned { dirCount[Self.normDir(card.projectDir), default: 0] += 1 }
        let uniqueDirs = Set(dirCount.filter { $0.value == 1 }.keys)
        // Identity binding beats the dir heuristic: a session spawned inside one of our
        // ptys carries that card's UUID (GHOSTLING_CARD_ID → hook line), so it binds to
        // its owned card even when several task cards share the repo dir and the dir
        // join is suppressed. This is what kills the "unclickable duplicate card".
        let adopted = owned.map { card in
            let byDir = uniqueDirs.contains(Self.normDir(card.projectDir))
            let bound = observed.filter { $0.boundCardID == card.id.uuidString }
            if let freshest = bound.max(by: { Self.staler($0, $1) }) {
                return smoothLiveState(card: card, observed: freshest.state)
            }
            if let state = liveState(forDir: card.projectDir, id: card.sessionID, joinByDir: byDir, in: observed) {
                return smoothLiveState(card: card, observed: state)
            }
            idleHoldUntil.removeValue(forKey: card.id)
            return card
        }
        // Board shows ONLY sessions we created here (owned cards). Claude sessions in
        // OTHER terminals still stream hook events — that's how `adopted` above moves an
        // owned card's column — but we never surface an external session as its own card
        // (they were un-openable: no PTY to drill into, e.g. the hidden `usage-probe`).
        // ponytail: drop the observed-but-unowned cards entirely. If a live overview of
        // other-terminal agents is ever wanted, re-add a collapsed, clearly-"observed",
        // read-only lane instead of mixing them in with drillable task cards.
        let merged = adopted
        let signature = merged.map { "\($0.sessionID)|\($0.state.rawValue)|\($0.projectDir)" }
        guard signature != lastSessionsSignature else { return }
        lastSessionsSignature = signature
        cards = merged   // ptyByCard keeps its owned entries → drill-in still works
        // US-005: re-render even while drilled in so the board (and the always-visible
        // attention badge) reflect reality on return, not a frozen snapshot. The focused
        // terminal lives in the separate `drillIn` panel; while drilled, `boardView`,
        // `attention`, and `quota` are all hidden, so `refresh()` rebuilds hidden card
        // views without touching the live terminal's superview. ponytail: full refresh,
        // no teardown — the old `focusedCardID == nil` guard is gone.
        refresh()
    }

    // A model "thinking" between tool calls emits no hook events for many seconds,
    // so the observed state dips to idle mid-turn; 2s was shorter than routine
    // thinking gaps and the card stuttered working→idle→working. Only a SUSTAINED
    // idle should demote the card — attention/blocked/done stay immediate.
    private static let idleHoldInterval: TimeInterval = 15.0

    /// Hook snapshots can briefly report `idle` between active tool events, and a
    /// long-running tool call (a 2-minute build emits nothing between PreToolUse and
    /// its result) decays to `unknown` via the stale sweep. Holding these two
    /// working→at-rest live transitions prevents column jitter while keeping
    /// attention, blocked, done, and manual moves immediate.
    private func smoothLiveState(card: BoardCard, observed state: CardState) -> BoardCard {
        let next = startedSafe(card: card, observed: state)
        guard state == .idle || state == .unknown,
              card.state == .running || card.state == .runningTests else {
            idleHoldUntil.removeValue(forKey: card.id)
            return card.with(state: next)
        }
        let now = Date()
        let deadline = idleHoldUntil[card.id] ?? now.addingTimeInterval(Self.idleHoldInterval)
        idleHoldUntil[card.id] = deadline
        return now < deadline ? card : card.with(state: next)
    }

    /// Apply sticky terminal state without guessing attention. A stopped or stale
    /// observation should render as idle/unknown, while a completed card stays
    /// completed until the operator manually moves it. Explicit notification/permission
    /// events carry `.waitingForInput` only for non-terminal cards.
    private func startedSafe(card: BoardCard, observed state: CardState) -> CardState {
        if manuallyReopenedDoneCardIDs.contains(card.id) {
            if state == .done { return card.state }
            if state == .running || state == .runningTests {
                manuallyReopenedDoneCardIDs.remove(card.id)
            }
        }
        return card.state.detectorFallback ?? state
    }

    /// The live state to show on an owned terminal card: the detected state of the
    /// hook-observed agent session correlated to it — matched by exact session id, and
    /// (only when `joinByDir`, i.e. the dir is unique to this card) by project dir. The
    /// dir join is suppressed for a repo shared by several task cards, where cwd can't
    /// say which task an agent belongs to. `nil` when no session matches yet, so the
    /// card keeps its seed state. When several sessions share the dir — an old finished
    /// run plus a fresh one — the FRESHEST observation wins (newest `updatedAt`) so the
    /// card tracks what's live now; activity-rank is only the tiebreak among
    /// equally-fresh states. This is what stops a STALE `blocked`/`waiting` from a
    /// finished run out-ranking a FRESH `running` (US-002).
    private func liveState(forDir dir: String, id: String, joinByDir: Bool, in observed: [BoardCard]) -> CardState? {
        let dir = Self.normDir(dir)
        return observed
            .filter { $0.sessionID == id || (joinByDir && Self.normDir($0.projectDir) == dir) }
            .max { Self.staler($0, $1) }
            .map(\.state)
    }

    /// Order two cards from "most stale" to "most live": the newer observation
    /// (`updatedAt`) is more live; equal timestamps fall back to activity-rank. So
    /// `max(by:)` yields the freshest, then highest-activity, card — the single
    /// freshness ordering both the owned-card join and the observed-to-observed
    /// collapse share (US-002 AC#2).
    private static func staler(_ lhs: BoardCard, _ rhs: BoardCard) -> Bool {
        lhs.updatedAt != rhs.updatedAt
            ? lhs.updatedAt < rhs.updatedAt
            : activityRank(lhs.state) < activityRank(rhs.state)
    }

    /// Normalize a project-dir string for the "one agent per dir" join, so a launch-CWD
    /// vs hook-`cwd` spelling difference (trailing slash, `.`/`..`, `/private` symlink)
    /// doesn't split one project into two cards.
    private static func normDir(_ dir: String) -> String {
        (dir as NSString).standardizingPath
    }

    /// How "live right now" a state is, for picking among several agent sessions that
    /// have run in one terminal: one that needs you or is working outranks one that
    /// has finished or gone idle/unknown.
    private static func activityRank(_ state: CardState) -> Int {
        switch state {
        case .blocked, .waitingForInput: return 5
        case .runningTests:              return 4
        case .running:                   return 3
        case .done:                      return 2
        case .idle:                      return 1
        case .unknown:                   return 0
        }
    }
}
