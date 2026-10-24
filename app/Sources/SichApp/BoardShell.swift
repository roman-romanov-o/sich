import AppKit
import SichCore
import UserNotifications

/// The board window: hosts the mission-control ``BoardView``, the quota panel
/// and the ``DrillInPanel`` overlay, wired to a
/// ``SessionRegistry`` of seeded sessions. This is the launchable,
/// screenshottable Phase 03 surface (US-002/003/005 rendering).
///
/// It owns the live model: a `[BoardCard]` snapshot plus the map from card id →
/// `PTYSession` so a drill-in (US-002) can mount the right embedded terminal. It
/// never spawns `claude -p` — every session launches through the registry's pool
/// firewall.
@MainActor
public final class BoardShell: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let registry = SessionRegistry()
    private let seeds: [BoardSeed]
    private var quotaSources: [QuotaSourceInput]

    private var window: NSWindow?
    // Internal (not private) so a real view-level test can assert the drill-in
    // hierarchy — the iter-2 sign-off proved BoardSelection's value-type test does
    // not cover whether the board is actually hidden / restored on screen.
    let boardView = BoardView()
    /// Backlog storage and its page remain implemented, but the unfinished section
    /// has no board or menu entry point until it is ready to ship.
    let backlogPage = BacklogPage()
    /// The dedicated view for tasks archived off the DONE column (checklist:
    /// "DONE column need to be archived time to time").
    let archivePage = ArchivePage()
    let drillIn = DrillInPanel()
    private(set) var createPalette: CreateCardPalette?
    // The quota panel folded in as a right-side region — one assembled window
    // shows the board AND the four never-netted gauges (no separate binary).
    let quota = QuotaPanel()
    /// The panel's width constraint — its constant tracks ``QuotaLayout/panelWidth``,
    /// which scales with the board font, so a zoom can't clip the gauges off-window.
    private var quotaWidth: NSLayoutConstraint?
    /// The board + quota edges that depend on where the panel docks, one set per
    /// ``QuotaDock`` side; exactly one is active (see ``dockQuota(_:)``).
    private var trailingDockConstraints: [NSLayoutConstraint] = []
    private var bottomDockConstraints: [NSLayoutConstraint] = []
    // The live data bridge — fully native after the Phase-03 cutover (DD-001/DD-002):
    // quota reads in-process from disk (no `GET /quota`, no sidecar) and sessions
    // arrive by tailing the observe-only event file (no `/sessions`, no port).
    // Started only on the real launch path (not in tests).
    private var quotaPoller: NativeQuotaPoller?
    /// Named agent accounts (Claude / Codex / Cursor config roots).
    private var agentAccountStore = AgentAccountStore()
    /// Also the board's link-health source (US-007): the relays it supervises are the
    /// only thing that knows whether a host still answers. Internal so a test can
    /// drive the real relay path through a stand-in transport, never a real ssh.
    var sessionsPoller: SessionsPoller?
    // The always-on pty drain (the fix for "work stops when I leave the task"): one
    // main-run-loop timer that reads EVERY owned session's pty each tick — not just
    // the drilled-in one — so an off-screen agent's child never blocks on a full
    // kernel buffer. Its own surface drains the drilled-in card, so the pump skips it.
    private var sessionPumpTimer: Timer?
    // Ctrl+Tab task-switch monitor — retained so it can be torn down; installed only
    // on the real launch path, never the headless test build (tests feed real NSEvents
    // through handleTaskSwitchEvent directly, so no event-loop dependency).
    private var taskSwitchMonitor: Any?
    /// Focus history, most recent first — the Ctrl+Tab switcher's ranking signal.
    private var mruOrder: [UUID] = []
    /// The Ctrl+Tab preview overlay plus its open-state snapshot. The list is frozen
    /// at open so live status changes can't reshuffle it under the operator's fingers
    /// mid-scroll; an empty snapshot means the switcher is closed.
    let taskSwitcher = TaskSwitcherOverlay()
    private(set) var switcherSnapshot: [BoardCard] = []
    private(set) var switcherIndex = 0
    var switcherIsOpen: Bool { !switcherSnapshot.isEmpty }
    private(set) var drilledInCardID: UUID?
    // Pump ticks since launch — the reconcile pass piggybacks on the pump timer at
    // a ~1s cadence (one waitpid(WNOHANG) per live session; no extra timer).
    private var pumpTick = 0
    // Cards whose child died WHILE drilled in: the surface shows the end banner
    // first; the card is swept off the board when the operator returns to it.
    private var deadCardIDs: Set<UUID> = []
    /// Attention count at the previous render — alerts fire only on a RISE, and the
    /// Dock badge shows it. Readable so tests can prove a live re-render landed.
    private(set) var lastAttentionCount = 0
    /// Rule 1 standup: avoid stacking modals; snooze stored in UserDefaults.
    private var needsYouStandupOpen = false
    // Per-card state at the previous render — a "task done" notification fires on
    // the rising edge into `.done` (not every refresh while it stays done).
    private var lastCardStates: [UUID: CardState] = [:]
    // Last applied live-session snapshot signature — re-render only on a real change
    // so the 3s poll doesn't tear down and rebuild identical card views (flicker).
    private var lastSessionsSignature: [String] = []
    private var idleHoldUntil: [UUID: Date] = [:]
    /// Choice-screen waits inferred from terminal pixels. Hook-derived Needs You
    /// states are deliberately absent so a normal Codex prompt cannot clear them.
    private var codexChoiceWaitingCardIDs: Set<UUID> = []
    // User intent, not detector output: only a manual drop to DONE survives a restart
    // as DONE. Everything else starts from queue and must earn WORKING again from
    // fresh observations in the current app session.
    private var manuallyDoneCardIDs: Set<UUID> = []
    // The other two columns that are operator intent rather than detector output:
    // BLOCKED (you are waiting on someone else) and PARKED (you shelved it). The
    // session under such a card is usually alive and sitting at a prompt, so its
    // next `Stop` reports `waiting-for-input` — which dragged the card straight back
    // to NEEDS YOU seconds after the drop (docs/OPERATING-RULES.md rule 1).
    private var operatorHeldCardIDs: Set<UUID> = []
    private var selection = BoardSelection()
    private(set) var cards: [BoardCard] = []
    private var ptyByCard: [UUID: PTYSession] = [:]
    var launchOverrideForTesting: ((BoardSeed) -> Session?)?
    /// Durable task persistence — the task, not the session, is the root entity.
    /// `nil` disables writes entirely: unit tests and the E2E capture harness stay
    /// side-effect free; the real launch installs the Application Support store and
    /// persistence tests inject a temp-dir store.
    var taskStore: BoardTaskStore?
    /// Item 6 (18.08): the per-task who-worked-when journal. `nil` in tests unless
    /// injected, so suites never write into the real Application Support.
    var workLog: TaskWorkLog?
    /// One-way Notion → backlog import. `nil` without a token in `notion.json`, and
    /// always in tests/E2E (same guard as the task store).
    var notionImporter: NotionImporter?
    /// Backlog: durable task intent with no session yet. Array order = render order.
    private(set) var backlogTasks: [TaskRecord] = []
    /// Archived tasks: finished work that left the board but stays durable in the
    /// task book (`archivedAt != nil`). Rendered only by ``archivePage`` — never a
    /// card, so a long history stops taxing every board refresh.
    private(set) var archivedTasks: [TaskRecord] = []
    /// The per-card slice of a ``TaskRecord`` the board model doesn't hold itself
    /// (description, launch mode, creation time) — joined by card id and written
    /// into the task book on every mutation.
    private var taskMetaByCard: [UUID: CardTaskMeta] = [:]
    /// Seeded utility cards (the launch live-terminal) are session furniture, not
    /// operator tasks — excluded from the task book so they don't accrete a new
    /// durable record on every app launch.
    private var seededCardIDs: Set<UUID> = []
    /// Provisions one git worktree per task (`createSession(inWorktree:)`) —
    /// injectable so tests never mint real worktrees in this repo.
    var worktreeProvisioner: any WorktreeProvisioning = GitWorktreeProvisioner()
    // Repo root for the live-terminal cwd and the hook installer (resolved once).
    private let repoRoot = RepoLocator.repoRoot()
    // Monotonic suffix so each add-task card gets a unique sessionID.
    private var sessionCounter = 0
    /// Asks a remote host what holds a tmux session name (US-004 AC-4) — injectable so
    /// tests answer without ssh. The default refuses to spawn under `swift test`.
    var remoteSessionRunner: any RemoteCommandRunner = SSHCommandRunner()
    /// Why the last remote-card attempt was refused, for the operator-facing alert.
    private(set) var lastRemoteSessionIssue: RemoteSessionIssue?
    private(set) var terminalFontSize: CGFloat = 20

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
        // Paint the board immediately. Quota construction and live reads are an
        // independent startup concern: a slow transcript walk must never delay the
        // first usable event-loop turn for the rest of the application.
        refresh(includeQuota: false)
        DispatchQueue.main.async { [weak self] in self?.startQuotaPolling() }
        // First paint should not wait for shell/PTY spawns, saved-session restore,
        // quota disk walks, event-tail setup, or idempotent integration installs.
        // Build and order the window first; hydrate the board just after AppKit gets
        // a chance to present that empty-but-usable shell.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.finishStartupAfterFirstPaint()
        }
    }

    private func finishStartupAfterFirstPaint() {
        // The durable task store comes up before restore so hydration can read the
        // task book and rewrite it. Skipped under SICH_E2E (captures must not
        // touch — or be polluted by — the real Application Support book).
        if taskStore == nil, ProcessInfo.processInfo.environment["SICH_E2E"] == nil {
            taskStore = BoardTaskStore.applicationSupport()
            workLog = TaskWorkLog.applicationSupport()
            notionImporter = NotionConfig.load(from: NotionConfig.applicationSupportURL).map {
                NotionImporter(api: NotionClient(config: $0), store: .applicationSupport())
            }
            // Item 8 (18.08): only the real app teaches the spawn geometry — the same
            // guard that keeps tests/E2E out of the operator's Application Support
            // keeps them out of the operator's UserDefaults.
            drillIn.teachesGeometry = true
        }
        // US-003: reload + re-open the pre-quit session tree before the fresh seed lands.
        restorePreviousSessions()
        seedSessions()
        refresh()
        startSessionPump()
        startSessionsBridge()
        startNotionImport()
        installPostLaunchIntegrations()
        handleLaunchCaptureRequests()
        registerNeedsYouStandupObserver()
        presentNeedsYouStandupIfNeeded()
        maybeRunE2E()
    }

    private func handleLaunchCaptureRequests() {
        // Capture seam: `SICH_OPEN_PALETTE=1` opens the ⌘N create palette on launch
        // so a screenshot tool can grab the real composited chrome (not a CALayer render).
        if ProcessInfo.processInfo.environment["SICH_OPEN_PALETTE"] != nil {
            openCreatePalette()
            // Capture the richest stage without keystroke automation: jump straight in.
            if ProcessInfo.processInfo.environment["SICH_PALETTE_STAGE"] == "harness",
               let dir = recentProjectDirs().first {
                createPalette?.presentHarnessStage(projectDir: dir)
            }
            if let n = window?.windowNumber { FileHandle.standardError.write(Data("SICH_WINDOW=\(n)\n".utf8)) }
        }
    }

    /// `SICH_E2E=1` → once the window has rendered and the first native poll has
    /// had time to land, run the on-screen smoke and exit with its verdict.
    /// No-op for a normal launch (the harness is never even constructed).
    private func maybeRunE2E() {
        guard ProcessInfo.processInfo.environment["SICH_E2E"] != nil,
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

    /// E2E-only: the card's current terminal screen — failure-time diagnostics for a
    /// harness that otherwise has no eyes on what the shell/agent actually printed.
    func e2eScreenText(of card: BoardCard) -> String {
        guard let pty = ptyByCard[card.id] else { return "" }
        return (try? pty.terminal.plainText()) ?? ""
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stopSessionPump()
        quotaPoller?.stop()
        sessionsPoller?.stop()
        // Capture the still-running interval in the durable task total before the
        // session snapshot deliberately parks non-DONE cards back in Queue.
        persistTasks()
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
    private func startQuotaPolling() {
        // Show the injected connecting/demo state first. This work is deliberately
        // on the post-launch turn, after the window is already ordered and usable.
        applyQuota(sources: quotaSources)
        // In E2E (design-review capture) keep the seeded two-pool demo quota on
        // screen: the native reader would overwrite it with the honest interactive +
        // all-"unknown" reading (no provider wiring yet for the other three pools),
        // hiding the pool contrast the capture exists to show.
        if ProcessInfo.processInfo.environment["SICH_E2E"] == nil {
            let profiles = agentAccountStore.profiles
            let poller = NativeQuotaPoller(profiles: profiles) { [weak self] sources in
                self?.applyQuota(sources: sources)
            }
            poller.start()
            self.quotaPoller = poller
        }
    }

    private func claudeProfileByCardMap() -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        for (cardID, meta) in taskMetaByCard {
            if let pid = meta.claudeProfileID { map[cardID] = pid }
        }
        return map
    }

    private func accountEnvExports(for profileID: UUID?, agent: CardAgent) -> String {
        AgentAccountBackend.shellEnvExports(
            accountID: profileID, in: agentAccountStore.accounts, agent: agent)
    }

    private func agentAccount(for profileID: UUID?) -> AgentAccountProfile? {
        agentAccountStore.account(id: profileID)
    }

    private func restartQuotaPoller() {
        quotaPoller?.stop()
        guard ProcessInfo.processInfo.environment["SICH_E2E"] == nil else { return }
        let poller = NativeQuotaPoller(profiles: agentAccountStore.profiles) { [weak self] sources in
            self?.applyQuota(sources: sources)
        }
        poller.start()
        quotaPoller = poller
    }

    private func startSessionsBridge() {
        adoptSessionsPoller(SessionsPoller(
            sink: { [weak self] cards in self?.applySessions(cards) }
        ))
    }

    /// Bring the sessions poller up. Also the test seam for the REAL launch order,
    /// in which the poller is created AFTER the pre-quit session tree is restored —
    /// so the remote sessions restore already put in the registry are followed here,
    /// not left to a restore-time `sessionsPoller?.attachRemoteHost` that found no
    /// poller and silently dropped the attach (every remote card came back as an
    /// unobserved terminal that never moved until a NEW card on that host was opened).
    func adoptSessionsPoller(_ poller: SessionsPoller) {
        poller.start()
        sessionsPoller = poller
        for spec in registry.all.compactMap(\.remoteSpec) {
            poller.attachRemoteHost(spec)
        }
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

    // Adaptive cadence, mirroring TerminalSurface: 60Hz while any background child
    // produces output, 4Hz once ALL have been quiet ~1s. Back-pressure safety is
    // unaffected — even 4Hz full drains outrun a ~64KB tty buffer for a quiet child,
    // and the first busy tick upshifts again.
    // ponytail: still polling non-blocking fds; swap for kqueue only if the 4Hz
    // idle wakeups ever show up in a power profile.
    private static let pumpActiveHz = 60.0
    private static let pumpIdleHz = 4.0
    private var pumpIdleTicks = 0
    private var pumpHz = pumpActiveHz
    private var lastCodexScanGeneration: [UUID: UInt64] = [:]

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
        where id != drilledInCardID && pty.masterFD >= 0 {
            pty.setNonBlocking()          // idempotent
            if case .data = pty.pumpAvailable() { sawData = true }
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
        for card in cards where card.agent == .codex && card.state != .done {
            let id = card.id
            guard let pty = ptyByCard[id], pty.masterFD >= 0 else { continue }
            let generation = pty.outputGeneration
            guard lastCodexScanGeneration[id] != generation else { continue }
            lastCodexScanGeneration[id] = generation
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
        if waiting {
            // Only claim ownership of a wait WE originated. If the card is already
            // waiting (e.g. a hook PermissionRequest/Notification put it there), leave
            // that hook-owned state untouched so a later clear of the pixel screen
            // can't stomp a still-pending Needs You that the terminal can't see.
            if cards[index].state != .waitingForInput {
                codexChoiceWaitingCardIDs.insert(cardID)
                cards[index] = cards[index].with(state: .waitingForInput)
                refresh()
                persistTasks()
            }
        } else if codexChoiceWaitingCardIDs.remove(cardID) != nil,
                  cards[index].state == .waitingForInput {
            cards[index] = cards[index].with(state: .running)
            refresh()
            persistTasks()
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
            captureResumeHints(for: cardID)   // the session is about to leave the registry
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
    /// A REMOTE card is the exception — its dead child is `ssh`, a dropped LINK, not
    /// a finished task: tmux keeps the far side running, so the card stays and goes
    /// idle until the next drill-in re-attaches it.
    private func removeDeadCard(_ cardID: UUID) {
        ptyByCard.removeValue(forKey: cardID)?.finish()   // child reaped; just closes the fd
        deadCardIDs.remove(cardID)
        if demoteDeadRemoteCard(cardID) { return }
        cards.removeAll { $0.id == cardID }
        refresh()
    }

    /// Freeze a dying session's resume hints into the card's durable meta, at the one
    /// moment they can still be read: the session leaves the registry a few lines
    /// later, after which ``sessionRef(for:)`` has nothing to join and falls back to
    /// this meta. Without it a dropped link DISCARDED the conversation id and the
    /// far-side cwd the card had just learned, and the re-attach after it had nothing
    /// left to come back to.
    private func captureResumeHints(for cardID: UUID) {
        guard ptyByCard[cardID] != nil,
              let card = cards.first(where: { $0.id == cardID }) else { return }
        taskMetaByCard[cardID, default: CardTaskMeta()].sessionRef = sessionRef(for: card)
    }

    /// If `cardID` is a remote card, keep it on the board as session-less idle
    /// (unless the operator marked it done) and persist that. Returns whether the
    /// card was remote — i.e. whether removal must be skipped.
    private func demoteDeadRemoteCard(_ cardID: UUID) -> Bool {
        guard let index = cards.firstIndex(where: { $0.id == cardID }),
              RemoteSessionKey.parse(sessionID: cards[index].sessionID) != nil
        else { return false }
        if !manuallyDoneCardIDs.contains(cardID), !operatorHeldCardIDs.contains(cardID) {
            cards[index] = cards[index].with(state: .idle)
        }
        refresh()
        persistTasks()
        return true
    }

    // MARK: - Session resume (US-003) + shell integration (US-004)

    /// US-003 launch side: on a normal launch, reload and re-open the pre-quit session
    /// tree. Skipped under `SICH_E2E` so the design-review capture shows only its
    /// scripted board, not whatever real shells were open last time. The restored cards
    /// are rendered by the launch `refresh()` that runs right after seeding.
    private func restorePreviousSessions() {
        guard ProcessInfo.processInfo.environment["SICH_E2E"] == nil else { return }
        hydratePersistedState(sessionStore: SessionSnapshotStore.applicationSupport(),
                              restorer: makeLaunchRestorer())
    }

    /// Launch-time hydration, task-book first: restore the pre-quit session tree
    /// (US-003), then overlay the durable task book — the AUTHORITY on which tasks
    /// exist. A board task the session layer failed to bring back (crash before the
    /// quit-time snapshot, dead pane) resurrects as a session-less queue card
    /// instead of silently vanishing; backlog tasks rejoin the backlog rail.
    func hydratePersistedState(sessionStore: SessionSnapshotStore, restorer: SessionRestorer) {
        let book = taskStore?.load()
        _ = restoreOnLaunch(store: sessionStore, restorer: restorer)
        adoptTaskBook(book)
    }

    /// Test seam: the exact launch hydration (task book + session snapshot through
    /// the REAL restorer that rebuilds cards), against injected stores.
    func hydrateForTesting(sessionStore: SessionSnapshotStore) {
        hydratePersistedState(sessionStore: sessionStore, restorer: makeLaunchRestorer())
    }

    /// Fold the loaded task book onto the board. No book yet but restored cards →
    /// first launch after the upgrade: synthesize the book from what the session
    /// snapshot brought back (migration), so the next crash is already covered.
    private func adoptTaskBook(_ book: TaskBook?) {
        guard let book else {
            persistTasks()
            return
        }
        for record in book.tasks {
            adoptRecord(record)
        }
        persistTasks()
    }

    /// Route one loaded record. Already-archived records rejoin the archive; a
    /// record finished in a PREVIOUS session archives NOW — that is the "time to
    /// time": every launch sweeps yesterday's DONE column into the archive, so the
    /// board only ever shows work finished since it last opened.
    private func adoptRecord(_ record: TaskRecord) {
        if record.archivedAt != nil {
            adoptArchivedRecord(record)
            return
        }
        switch record.placement {
        case .backlog: backlogTasks.append(record)
        case .board(.done): archiveOnLaunch(record)
        case .board(let state): adoptBoardRecord(record, state: state)
        }
    }

    private func adoptArchivedRecord(_ record: TaskRecord) {
        archivedTasks.append(record)
        discardRestoredCard(id: record.id)
    }

    private func archiveOnLaunch(_ record: TaskRecord) {
        var archived = record
        archived.archivedAt = Date()
        adoptArchivedRecord(archived)
    }

    /// The session snapshot may have restored (and re-spawned a shell for) a card
    /// the book says is archived — tear that card down so the task lives ONLY in
    /// the archive. Same teardown as ``deleteCard`` minus the worktree removal:
    /// archiving preserves the work, deleting destroys it.
    private func discardRestoredCard(id: UUID) {
        guard cards.contains(where: { $0.id == id }) else { return }
        let pty = ptyByCard.removeValue(forKey: id)
        pty?.terminate()
        if let pty, let dead = registry.all.first(where: { $0.pty === pty }) {
            registry.remove(id: dead.id)
        }
        cards.removeAll { $0.id == id }
        deadCardIDs.remove(id)
        idleHoldUntil.removeValue(forKey: id)
        codexChoiceWaitingCardIDs.remove(id)
        lastCardStates.removeValue(forKey: id)
        taskMetaByCard.removeValue(forKey: id)
        manuallyDoneCardIDs.remove(id)
        operatorHeldCardIDs.remove(id)
    }

    /// One board-placed record rejoins the board: its metadata attaches to the
    /// already-restored card with the same id; a record with NO surviving card comes
    /// back as a session-less card in its durable column — the task outlives its shell.
    private func adoptBoardRecord(_ record: TaskRecord, state: CardState) {
        taskMetaByCard[record.id] = CardTaskMeta(
            details: record.details, createdAt: record.createdAt,
            sessionRef: record.sessionRef, remote: record.remote?.spec,
            claudeProfileID: record.claudeProfileID,
            needsYouDeferredUntil: record.needsYouDeferredUntil
        )
        BoardTheme.linkProject(card: record.id, toDirectory: record.remote?.spec.remoteDir)
        if state == .done { manuallyDoneCardIDs.insert(record.id) }
        if state == .blocked || state == .parked { operatorHeldCardIDs.insert(record.id) }
        if let index = cards.firstIndex(where: { $0.id == record.id }) {
            cards[index] = cards[index].with(
                accumulatedWorkingTime: record.accumulatedWorkingTime ?? 0)
            // The book is the authority on placement, and a held column is the one
            // placement the session snapshot could disagree about (it is written at
            // quit, the book on every mutation). Without this the card would restore
            // idle yet stay frozen there, held against its own record.
            if operatorHeldCardIDs.contains(record.id), cards[index].state != state {
                cards[index] = cards[index].with(state: state)
            }
            return
        }
        // A remote record keeps its `(host, session)` id — the string the duplicate
        // guard and the host chip read — never a bare UUID that would let a second
        // card claim the same far-side session.
        let remoteID = record.remote.flatMap { try? RemoteSessionKey.make(for: $0.spec) }
        cards.append(BoardCard(
            id: record.id,
            sessionID: remoteID?.sessionID ?? record.id.uuidString,
            title: record.title.isEmpty ? nil : record.title,
            projectDir: record.projectDir ?? NSHomeDirectory(),
            agent: record.agent.flatMap(CardAgent.init(rawValue:)) ?? .claude,
            state: state,
            accumulatedWorkingTime: record.accumulatedWorkingTime ?? 0
        ))
    }

    /// Write the durable task book — every backlog task plus every operator-created
    /// board card — through the injected store. Runs on each mutation (create, move,
    /// rename, delete, backlog edits), so a crash can never roll the board back to
    /// the last clean quit. No store configured → no-op.
    private func persistTasks() {
        guard let taskStore else { return }
        let board = cards
            .filter { !seededCardIDs.contains($0.id) }
            .map(taskRecord(for:))
        _ = try? taskStore.save(tasks: backlogTasks + board + archivedTasks)
    }

    /// A board card's durable record. Placement goes through
    /// ``persistedRestartState(for:)`` — the same restart policy the session snapshot
    /// applies: only a manual DONE is durable intent; everything else restarts from
    /// queue and must earn WORKING again from fresh observations.
    private func taskRecord(for card: BoardCard) -> TaskRecord {
        let meta = taskMetaByCard[card.id] ?? CardTaskMeta()
        return TaskRecord(
            id: card.id,
            title: card.title ?? "",
            details: meta.details,
            placement: .board(persistedRestartState(for: card)),
            agent: card.agent.rawValue,
            projectDir: card.projectDir,
            createdAt: meta.createdAt,
            sessionRef: sessionRef(for: card),
            accumulatedWorkingTime: card.totalWorkingTime(),
            remote: remoteSnapshot(for: card),
            claudeProfileID: taskMetaByCard[card.id]?.claudeProfileID,
            needsYouDeferredUntil: taskMetaByCard[card.id]?.needsYouDeferredUntil
        )
    }

    /// A remote card's durable spec: prefer the live session's record (the freshest
    /// truth), fall back to the meta carried from the loaded book so a save cycle
    /// on a session-less card never costs the task its attach recipe.
    private func remoteSnapshot(for card: BoardCard) -> RemoteSpecSnapshot? {
        if let session = ptyByCard[card.id].flatMap({ pty in
            registry.all.first { $0.pty === pty }
        }), let spec = session.remoteSpec {
            return RemoteSpecSnapshot(spec: spec)
        }
        return taskMetaByCard[card.id]?.remote.map(RemoteSpecSnapshot.init(spec:))
    }

    /// Resume hints only: the pinned Claude conversation id (if the card's session is
    /// driving one) and the last known cwd. Joined through the shared pty — the one
    /// identity the card and its registry session agree on.
    private func sessionRef(for card: BoardCard) -> TaskSessionRef {
        guard let session = ptyByCard[card.id].flatMap({ pty in
            registry.all.first { $0.pty === pty }
        }) else {
            // Session-less card: keep the adopted hints verbatim — a save cycle
            // must never cost the card its resume token.
            return taskMetaByCard[card.id]?.sessionRef
                ?? TaskSessionRef(claudeSessionID: nil, lastCwd: card.projectDir)
        }
        // The fallback is the card's own dir only for a LOCAL card, whose `projectDir`
        // IS a directory. A remote card's is the `user@host` label — not a path on
        // either machine — so until the far side reports one, it has no last cwd.
        return TaskSessionRef(
            claudeSessionID: session.claudeSessionID,
            lastCwd: session.reportedCwd ?? (session.remoteSpec == nil ? card.projectDir : nil)
        )
    }

    /// US-003 quit side: persist the live window/pane tree so the next launch can restore
    /// it. Injectable store so a test drives the exact quit path into a temp app-support
    /// dir. Best-effort — a write failure just means no resume, never a crash on quit.
    @discardableResult
    func persistOnTerminate(store: SessionSnapshotStore) -> SessionSnapshot? {
        try? store.save(windows: enrichedSnapshotWindows())
    }

    /// The registry snapshot, enriched with each pane's app-level card metadata (identity,
    /// human title, column) so a restart brings the *task* back, not just
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
            title: card.title,
            claudeProfileID: taskMetaByCard[card.id]?.claudeProfileID
        )
    }

    /// Only operator intent is durable: DONE, and the two held columns (BLOCKED /
    /// PARKED). A live state restarts from queue and must earn WORKING again from
    /// fresh observations. The held state is read off the card but clamped to the two
    /// legal values, so no detector state can leak into a file an older build reads.
    private func persistedRestartState(for card: BoardCard) -> CardState {
        if manuallyDoneCardIDs.contains(card.id) { return .done }
        guard operatorHeldCardIDs.contains(card.id),
              card.state == .blocked || card.state == .parked else { return .idle }
        return card.state
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
        SessionRestorer(
            accountEnv: { [weak self] profileID, agent in
                self?.accountEnvExports(for: profileID, agent: agent) ?? ""
            },
            accountFor: { [weak self] profileID in
                self?.agentAccount(for: profileID)
            },
            reopen: { [weak self] pane, command in
            MainActor.assumeIsolated { self?.openRestoredCard(pane: pane, command: command) }
        })
    }

    /// Launch one restored pane's shell and drop its card on the board — a login shell in
    /// the pane's cwd, launched through the registry (never `claude -p`). `command` is the
    /// firewall-clean `$SHELL -il` the restorer validated, so the watcher-not-spawner
    /// invariant holds; this method builds no agent command of its own.
    private func openRestoredCard(pane: RestoredPane, command: [String]) {
        // The session keeps the pane's agent type even though the argv is a bare shell:
        // `snapshotWindows` persists `session.agentType` on the NEXT quit, so `.shell`
        // here would turn a Cursor/Codex card into a bare shell (and a `.claude` card)
        // after exactly one restart, and its resume command would never be sent again.
        guard let session = try? registry.launch(
            command: command, projectDir: pane.cwd,
            agentType: pane.snapshot.agentType,
            rows: TerminalGeometry.preferred.rows, cols: TerminalGeometry.preferred.cols
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
        } else if pane.snapshot.agentType == .cursor, pane.liveness == .reopened {
            HookInstaller.installCursorHooks()
        } else if pane.snapshot.agentType == .antigravity, pane.liveness == .reopened {
            HookInstaller.installAntigravityHooks()
        }
        if let command = Self.restoredAgentCommand(for: pane.snapshot), pane.liveness == .reopened {
            _ = session.pty.send(Array(command.utf8))
        }
        // Identity and column both come from the snapshot. The id must be the ORIGINAL:
        // the shell we just re-opened exports it as SICH_CARD_ID, and a fresh UUID
        // here would leave every incoming hook line pointing at a card that doesn't exist,
        // freezing this card in place for the rest of the app's life.
        let card = BoardCard(
            id: pane.snapshot.cardID ?? UUID(),
            sessionID: Self.restoredSessionID(for: pane.snapshot),
            title: pane.snapshot.title, projectDir: pane.cwd,
            agent: Self.cardAgent(for: pane.snapshot.agentType),
            state: pane.snapshot.cardState ?? .idle
        )
        cards.append(card)
        if card.state == .done {
            manuallyDoneCardIDs.insert(card.id)
        }
        if card.state == .blocked || card.state == .parked {
            operatorHeldCardIDs.insert(card.id)
        }
        if taskMetaByCard[card.id] == nil {
            taskMetaByCard[card.id] = CardTaskMeta(
                claudeProfileID: pane.snapshot.claudeProfileID)
        } else if let profileID = pane.snapshot.claudeProfileID {
            taskMetaByCard[card.id]?.claudeProfileID = profileID
        }
        ptyByCard[card.id] = session.pty
        if let spec = pane.snapshot.remote?.spec {
            adoptRestoredRemote(spec, on: session)
            BoardTheme.linkProject(card: card.id, toDirectory: spec.remoteDir)
        }
    }

    /// Put a restored remote card back on the same footing a freshly created one has
    /// (US-006 AC-4): the session carries its spec again — so the NEXT quit persists it
    /// and the card survives an unbounded chain of restarts, not just one — the host's
    /// hook state is re-learned, and its event log is followed again. Without the relay
    /// the card comes back as an unobserved terminal: attached, but never moving.
    private func adoptRestoredRemote(_ spec: RemoteTmuxSpec, on session: Session) {
        session.recordRemoteSpec(spec)
        TmuxControlBridge.attachIfNeeded(to: session)
        RemoteHookStatus.shared.register(spec)
        sessionsPoller?.attachRemoteHost(spec)
    }

    /// A remote card's session id is its `(host, session)` key, not the pane's UUID:
    /// that is the string the duplicate guard reads, so a restored card must carry it
    /// or a second card could claim the very session this one is attached to.
    private static func restoredSessionID(for pane: PaneSnapshot) -> String {
        guard let spec = pane.remote?.spec,
              let key = try? RemoteSessionKey.make(for: spec)
        else { return pane.sessionID.uuidString }
        return key.sessionID
    }

    /// Which executable a typed launch line names. The board's status feed depends on the
    /// Sich shim (`~/.sich/bin/claude`) wrapping the real binary with per-invocation
    /// hooks; a LOCAL launch therefore names the shim by absolute path instead of
    /// trusting PATH order, which any later rc line (`export PATH="~/.local/bin:$PATH"`
    /// appended by another installer) silently defeats — the card then never hears a
    /// Stop and sticks in WORKING. A REMOTE launch is typed into a far-side shell that
    /// has no shim (its hooks arrive through the forwarded event log), so it stays a
    /// bare PATH lookup.
    enum HarnessLauncher {
        case localShim
        case remotePath

        var claudeExecutable: String {
            switch self {
            case .localShim: return "\"$HOME/\(HookInstaller.codexBinDirName)/\(HookInstaller.claudeShimName)\""
            case .remotePath: return "claude"
            }
        }

        var codexExecutable: String {
            switch self {
            case .localShim: return "\(HookInstaller.codexShimPath())/codex"
            case .remotePath: return "codex"
            }
        }

        var cursorExecutable: String {
            switch self {
            case .localShim: return "\(HookInstaller.codexShimPath())/agent"
            case .remotePath: return "agent"
            }
        }

        var antigravityExecutable: String {
            switch self {
            case .localShim: return "\(HookInstaller.codexShimPath())/agy"
            case .remotePath: return "agy"
            }
        }
    }

    /// The keystrokes that start a NEW Claude conversation pinned to `sessionID`, so we
    /// know the id up front and can resume it later. Lowercased to match Claude's own
    /// transcript-id form (what `--resume` looks up).
    static func startClaudeCommand(sessionID: UUID, via launcher: HarnessLauncher) -> String {
        "\(launcher.claudeExecutable) --session-id \(sessionID.uuidString.lowercased())\n"
    }

    /// The keystrokes that RESUME the conversation `sessionID` on a restored pane. Falls
    /// back to a fresh `claude` if the transcript is gone (resume exits non-zero), so a
    /// restore never lands the operator on a dead shell; stderr is dropped so the expected
    /// "no conversation" note doesn't flash before the fallback.
    static func resumeClaudeCommand(sessionID: UUID, via launcher: HarnessLauncher) -> String {
        let claude = launcher.claudeExecutable
        return "\(claude) --resume \(sessionID.uuidString.lowercased()) 2>/dev/null || \(claude)\n"
    }

    /// Prefer the explicit pinned Claude conversation id. For snapshots written before
    /// that field existed, a Claude pane's own session id is the best available resume
    /// token: newer create paths pinned Claude to that id, and if no transcript exists
    /// the generated command falls back to fresh interactive `claude`.
    static func claudeResumeID(for pane: PaneSnapshot) -> UUID? {
        pane.claudeSessionID ?? (pane.agentType == .claude ? pane.sessionID : nil)
    }

    static func restoredAgentCommand(for pane: PaneSnapshot) -> String? {
        // A remote pane comes back by ATTACHING: tmux kept the far side exactly as the
        // operator left it, so there is nothing to resume — and typing a resume command
        // into it would talk over whatever is already running in that session.
        if pane.remote != nil { return nil }
        if let claudeID = claudeResumeID(for: pane) {
            return resumeClaudeCommand(sessionID: claudeID, via: .localShim)
        }
        if pane.agentType == .codex {
            return resumeCodexCommand()
        }
        if pane.agentType == .cursor {
            return resumeCursorCommand()
        }
        if pane.agentType == .antigravity {
            return resumeAntigravityCommand()
        }
        return nil
    }

    /// Start a Cursor agent session in the already-open login shell.
    static func startCursorCommand(via launcher: HarnessLauncher = .localShim) -> String {
        "\(launcher.cursorExecutable)\n"
    }

    /// Resume the latest Cursor chat. Cursor owns its chat ids (`agent resume` picks
    /// the most recent), so like Codex we do not mint an app-level id.
    static func resumeCursorCommand(via launcher: HarnessLauncher = .localShim) -> String {
        "\(launcher.cursorExecutable) resume\n"
    }

    /// Start an Antigravity (`agy`) session in the already-open login shell.
    static func startAntigravityCommand(via launcher: HarnessLauncher = .localShim) -> String {
        "\(launcher.antigravityExecutable)\n"
    }

    /// Resume the latest Antigravity conversation (`--continue` picks the most
    /// recent one in this workspace); no app-level id is minted.
    static func resumeAntigravityCommand(via launcher: HarnessLauncher = .localShim) -> String {
        "\(launcher.antigravityExecutable) --continue\n"
    }

    /// Start a Codex CLI session in the already-open login shell.
    static func startCodexCommand(via launcher: HarnessLauncher = .localShim) -> String {
        "\(launcher.codexExecutable)\n"
    }

    /// Resume the most recent Codex interactive session for this cwd. Codex owns its
    /// saved session ids, so we use its cwd-filtered `--last` behavior instead of
    /// inventing an app-level id.
    static func resumeCodexCommand(via launcher: HarnessLauncher = .localShim) -> String {
        "\(launcher.codexExecutable) resume --last\n"
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

    /// Where the bundled shell-integration files live (Application Support), resolved
    /// once. Falls back to the temp dir if Application Support is unavailable.
    private static func shellIntegrationRoot() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sich/shell-integration", isDirectory: true)
    }

    /// The operator's `~/.zshrc` — the rc the integration source line is appended to.
    private static func defaultZshrc() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

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

    /// The pty a card's terminal is bound to (nil = no live shell).
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    func ptyForTesting(card: BoardCard) -> PTYSession? { ptyByCard[card.id] }

    /// Build the seeded board hierarchy **without** ordering a window on screen, so
    /// the drill-in interaction (board hidden on drill, restored on return) can be
    /// driven by a headless view-level test. Wires interactions exactly as
    /// `applicationDidFinishLaunching` does — otherwise the back-affordance callback
    /// (`drillIn.onClose → returnToBoard`) is unwired and a test would silently
    /// bypass the real Esc/click → return chain. Returns the root content view.
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    @discardableResult
    func buildContentForTesting(size: NSSize = NSSize(width: 1280, height: 720)) -> NSView {
        seedSessions()
        let root = makeContentView(in: size)
        wireInteractions()
        root.layoutSubtreeIfNeeded()
        return root
    }

    /// Test seam: is this PTY session held by the pool-firewalled registry?
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    func isRegistered(_ pty: PTYSession) -> Bool {
        registry.all.contains { $0.pty === pty }
    }

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    func taskMetaForTesting(_ cardID: UUID) -> CardTaskMeta? { taskMetaByCard[cardID] }

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    func switchMenusForTesting() -> [UUID: CardSwitchMenu] {
        let shown = displayCards()
        let gauges = QuotaProjection.gauges(from: quotaSources)
        return switchMenus(for: shown, gauges: gauges)
    }

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    func refreshForTesting() { refresh() }

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    func setAgentAccountsForTesting(_ accounts: [AgentAccountProfile]) {
        agentAccountStore = AgentAccountStore(accounts: accounts)
    }

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    func insertCardForTesting(_ card: BoardCard, remote: RemoteTmuxSpec? = nil) {
        cards.append(card)
        if let remote {
            taskMetaByCard[card.id, default: CardTaskMeta()].remote = remote
        }
    }

    // MARK: - Seeding

    private func seedSessions() {
        for seed in seeds {
            guard let session = launch(seed) else { continue }
            let card = BoardCard(
                id: seed.cardID.flatMap(UUID.init(uuidString:)) ?? UUID(),
                sessionID: seed.sessionID, title: seed.title, projectDir: seed.projectDir,
                agent: seed.agent, state: seed.state,
                workingSince: seed.state.isWorking
                    ? Date().addingTimeInterval(-seed.currentWorkingTime) : nil,
                accumulatedWorkingTime: seed.accumulatedWorkingTime
            )
            cards.append(card)
            ptyByCard[card.id] = session.pty
            seededCardIDs.insert(card.id)
        }
    }

    private func launch(_ seed: BoardSeed) -> Session? {
        if let launchOverrideForTesting {
            // The seam replaces the SPAWN, not the bookkeeping. Every path that joins a
            // card to its session — the resume hints, the remote spec, the far-side
            // facts a hook line teaches — looks the session up by pty in the registry,
            // so a session left unregistered makes all of them silently no-op under
            // test while working in production.
            return launchOverrideForTesting(seed).map { registry.register($0) }
        }
        guard let session = try? registry.launch(
            command: seed.command,
            projectDir: seed.projectDir,
            agentType: AgentType(rawValue: seed.agent.rawValue) ?? .shell,
            // Item 8 (18.08): spawn at the drill-in's remembered grid so the first
            // entry is a no-op resize — no reflow gap, the screen paints instantly.
            rows: TerminalGeometry.preferred.rows,
            cols: TerminalGeometry.preferred.cols
        ) else { return nil }
        ShellSignalBridge.attachCwdReporting(to: session)   // US-004: live OSC-7 cwd
        return session
    }

    // MARK: - Window

    /// A minimal main menu so ⌘N opens the create palette (the design's shortcut) and
    /// ⌘Q quits — `swift run` binaries start with no menu at all. ponytail: two items,
    /// no nib; grows only if more shortcuts are actually wanted.
    private func installMainMenu() {
        let appMenu = LayoutAwareMenu()
        appMenu.addItem(withTitle: "New Task", action: #selector(newTaskMenuAction),
                        keyEquivalent: "n").target = self
        appMenu.addItem(withTitle: "Agent Accounts…",
                        action: #selector(manageAgentAccountsMenuAction),
                        keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        // One ⌘+/⌘− pair for the whole app (checklist 18.08): on the board it scales
        // board type, inside a terminal takeover it sizes the terminal font. The old
        // ⌘⇧ terminal pair and the in-terminal pill are gone — context picks the
        // target, the shortcut stays the one from the main screen.
        appMenu.addItem(withTitle: "Increase Font",
                        action: #selector(increaseFontMenuAction),
                        keyEquivalent: "=").target = self
        appMenu.addItem(withTitle: "Decrease Font",
                        action: #selector(decreaseFontMenuAction),
                        keyEquivalent: "-").target = self
        appMenu.addItem(.separator())
        // Recovery affordance: if the window ever ends up larger than the screen
        // (its resize edges then sit off-screen and can't be grabbed), ⌘0 pulls
        // it back without restarting — a restart would kill every live session.
        appMenu.addItem(withTitle: "Fit Window to Screen",
                        action: #selector(fitWindowMenuAction),
                        keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sich", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let main = LayoutAwareMenu()
        main.addItem(appItem)
        main.addItem(EditMenu.item())   // without it ⌘V is dead in every text field
        NSApp.mainMenu = main
    }

    @objc private func newTaskMenuAction() { openCreatePalette() }
    @objc private func manageAgentAccountsMenuAction() { promptManageAgentAccounts() }
    @objc private func fitWindowMenuAction() { fitWindowToScreen() }
    @objc private func increaseFontMenuAction() { zoomFont(direction: 1) }
    @objc private func decreaseFontMenuAction() { zoomFont(direction: -1) }

    /// Route ⌘+/⌘− to whatever the operator is looking at: the terminal font while a
    /// terminal takeover (drill-in) is up, board typography otherwise.
    func zoomFont(direction: CGFloat) {
        if drilledInCardID != nil {
            changeTerminalFont(by: direction)
        } else {
            changeBoardFont(by: direction * 0.1)
        }
    }

    /// Disk-writing installs + the notification prompt, run one tick after launch so
    /// they never block the window's first paint. All are idempotent and degrade
    /// gracefully, so deferring them changes only *when* they run, not *whether*.
    private func installPostLaunchIntegrations() {
        SystemNotifier.requestAuthorization()
        // Clean up old global Sich Claude hooks from prior builds; status is now
        // scoped through managed PATH shims below, so global config would duplicate and
        // cross-contaminate unrelated Claude sessions.
        HookInstaller.uninstallGlobal()
        // Managed PATH shims inject hooks per invocation, cmux-style. This keeps
        // Claude/Codex status scoped to Sich-owned terminals instead of mutating
        // global agent config and cross-contaminating unrelated sessions.
        HookInstaller.installClaudeShim()
        HookInstaller.installCodexShim()
        HookInstaller.installCursorHooks()
        // The shim points Claude at `custom:sich`; this writes the file behind that
        // reference, so the child's TUI palette is the board's rather than a
        // dark-oriented default stranded on light paper.
        ClaudeTheme.install(for: NSApp.effectiveAppearance)
        // US-004: install Ghostty shell-integration the same way (idempotent; non-zsh
        // and write failures degrade gracefully) so the shell reports cwd semantically.
        installShellIntegration(installRoot: Self.shellIntegrationRoot(), rc: Self.defaultZshrc())
    }

    /// Ctrl+Tab / Ctrl+Shift+Tab opens the task switcher (a held-⌃ preview, VS Code
    /// style — release ⌃ to commit, Esc to cancel). A local key monitor is the single
    /// choke point that fires BEFORE the drilled-in terminal's first responder swallows
    /// the key — unlike ⌘-combos, a Control-modified key isn't reliably routed through
    /// `performKeyEquivalent`, and plain Tab belongs to the child. `.flagsChanged` is
    /// watched too: the ⌃ release is what commits the highlighted task. Works
    /// identically from the board and drill-in.
    private func installTaskSwitchMonitor() {
        taskSwitchMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            self?.handleTaskSwitchEvent(event) ?? event
        }
    }

    /// The monitor's single callback: a switch chord advances the preview, a ⌃ release
    /// commits it, Esc backs out. Instance method fed REAL `NSEvent`s — tests dispatch
    /// through this exact path, per the Interaction-AC Binding Rule. Returns `nil` to
    /// consume the event (never for `.flagsChanged`: modifier transitions belong to
    /// the app).
    func handleTaskSwitchEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            if switcherIsOpen, Self.isControlRelease(event) { commitSwitcher() }
            return event
        }
        if let reverse = Self.switchDirection(for: event) {
            advanceSwitcher(reverse: reverse)
            return nil   // consume it — never let plain Tab reach the child
        }
        if switcherIsOpen, event.keyCode == 53 {   // Esc closes without switching
            cancelSwitcher()
            return nil
        }
        return event
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

    /// A `.flagsChanged` with Control no longer held — the "commit" gesture while the
    /// switcher is up. Static + `NSEvent`-driven for the same test-dispatch reason.
    static func isControlRelease(_ event: NSEvent) -> Bool {
        event.type == .flagsChanged
            && !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
    }

    /// Columns are equal-width and flexible and card text truncates, so the board
    /// degrades gracefully when narrow — the floor only guards against a window too
    /// small to be usable, and must stay below a 1280×832 built-in laptop screen
    /// (the old 1360 floor made such screens impossible to resize on).
    static let minContentSize = NSSize(width: 640, height: 420)

    private func makeWindow() {
        let window = NSWindow(
            // 1400×860: wide enough that all 5 columns + the quota panel fit on
            // launch, yet still fits a 1440-wide laptop screen after .center().
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Sich — mission control"
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
        window.contentMinSize = Self.minContentSize
        window.contentView = makeContentView(in: window.frame.size)
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(boardView)   // arrow-key board navigation from launch
        self.window = window
        // The 1400×860 default fits a wide external display but overflows a smaller
        // built-in laptop screen. Correct that once on launch. Do not refit from
        // `windowDidChangeScreen`: it fires midway through a cross-display drag, and
        // changing the frame there traps the window on its original screen.
        fitWindowToScreen()
        // Unplugging the external display is the other way a window ends up wider
        // than its screen: macOS moves it to the built-in panel at its old size, so
        // the board's right edge (and the quota panel) hang off-screen. That
        // arrives as a screen-parameters change, never as a drag, so refitting
        // there is safe.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitWindowToScreen() }
        }
        // The fitted launch width may already be below the 1400pt design width
        // (a built-in laptop screen) — size the type to it before first paint.
        applyResponsiveLayout()
    }

    /// Shrink and reposition the window so it fits entirely inside its current
    /// screen's `visibleFrame` (menu bar and Dock excluded). Only ever shrinks —
    /// a window the user enlarged on a big display is left alone until it lands
    /// somewhere it no longer fits. This is what makes dragging from an external
    /// monitor onto the built-in screen not push content off the edges.
    private func fitWindowToScreen() {
        guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        // Never fight a native fullscreen window (or a transition into one):
        // setFrame mid-transition wedges AppKit's animation and can strand the
        // window at an off-screen oversized frame — the "stuck, can't resize" bug.
        guard !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        let fitted = Self.fittedFrame(frame, inside: visible)
        if fitted != frame { window.setFrame(fitted, display: true, animate: false) }
    }

    /// Pure geometry shared by launch/screen-change fitting and tests.
    static func fittedFrame(_ frame: NSRect, inside visible: NSRect) -> NSRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Make the green zoom control — and title-bar double-click when macOS is set
    /// to zoom — mean “fit this screen”. AppKit's default standard frame can retain
    /// an oversized user frame, which is precisely the state this affordance must
    /// recover from.
    public func windowWillUseStandardFrame(
        _ window: NSWindow, defaultFrame newFrame: NSRect
    ) -> NSRect {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return newFrame
        }
        return visible
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
        layoutQuota(in: root)
        layout(boardView, in: root)
        dockQuota(QuotaLayout.dock(forContentSize: size))
        drillIn.isHidden = true
        layoutDrillIn(in: root)
        backlogPage.isHidden = true
        layoutFullWindow(backlogPage, in: root)
        archivePage.isHidden = true
        layoutFullWindow(archivePage, in: root)
        layoutFullWindow(taskSwitcher, in: root)   // last = topmost: floats over any mode
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

    /// The quota panel docks on one of two sides (``QuotaDock``). Trailing: a
    /// fixed-width column from just under the header to the bottom, the board
    /// filling the width left of it. Bottom: a full-width strip as tall as its
    /// cards — capped so it can never crowd the board out — with the board above.
    private func layoutQuota(in root: NSView) {
        quota.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(quota)
        let width = quota.widthAnchor.constraint(equalToConstant: QuotaLayout.panelWidth)
        quotaWidth = width
        quota.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        quota.bottomAnchor.constraint(equalTo: root.bottomAnchor).isActive = true
        trailingDockConstraints = [
            quota.topAnchor.constraint(equalTo: root.topAnchor),
            width,
        ]
        bottomDockConstraints = [
            quota.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            quota.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, multiplier: 0.4),
        ]
    }

    /// Move the quota panel to `dock` and give the board the space that leaves.
    private func dockQuota(_ dock: QuotaDock) {
        quota.dock = dock
        boardView.isDoneNarrow = dock != .trailing
        NSLayoutConstraint.deactivate(trailingDockConstraints + bottomDockConstraints)
        NSLayoutConstraint.activate(
            dock == .trailing ? trailingDockConstraints : bottomDockConstraints)
    }

    private func layout(_ view: NSView, in root: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate(boardConstraints(view, in: root))
    }

    private func boardConstraints(_ v: NSView, in root: NSView) -> [NSLayoutConstraint] {
        // Board fills the width left of a trailing quota column (not the full
        // root), or the full width above a bottom quota strip.
        trailingDockConstraints += [
            // Flush: the panel's own leading hairline is the lane boundary.
            v.trailingAnchor.constraint(equalTo: quota.leadingAnchor),
            v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        bottomDockConstraints += [
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: quota.topAnchor),
        ]
        return [
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            v.topAnchor.constraint(equalTo: root.topAnchor),
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
        boardView.onSwitchAccount = { [weak self] in self?.switchAccount(on: $0, to: $1) }
        boardView.onSwitchHarness = { [weak self] in self?.switchHarness(on: $0, to: $1) }
        boardView.onDeferNeedsYou = { [weak self] in self?.deferNeedsYouToTomorrow(cardID: $0.id) }
        backlogPage.onReturn = { [weak self] in self?.hideBacklogPage() }
        backlogPage.onAdd = { [weak self] in self?.promptAddBacklogTask() }
        backlogPage.onPromote = { [weak self] record in
            guard let self else { return }
            // A successful promote puts a card on the board — follow it there.
            if self.promptPromoteBacklogTask(record) != nil {
                self.hideBacklogPage()
            }
        }
        backlogPage.onDelete = { [weak self] in self?.deleteBacklogTask(id: $0.id) }
        boardView.onShowArchive = { [weak self] in self?.showArchivePage() }
        archivePage.onReturn = { [weak self] in self?.hideArchivePage() }
        archivePage.onRevive = { [weak self] record in
            self?.reviveArchivedTask(id: record.id)
        }
        drillIn.onClose = { [weak self] in self?.returnToBoard() }
    }

    private func changeBoardFont(by delta: CGFloat) {
        BoardTheme.boardFontScale = min(1.8, max(1.0, BoardTheme.boardFontScale + delta))
        reflowBoardTypography()
    }

    /// Re-render everything whose metrics derive from the scaled board fonts —
    /// the manual ⌘+/⌘− zoom and the responsive window-width shrink share this.
    private func reflowBoardTypography() {
        // The dock rides along: how many quota cards fit a bottom strip depends on
        // the zoomed card width, and a dock flip re-renders the same surfaces.
        if let size = window?.contentView?.frame.size {
            dockQuota(QuotaLayout.dock(forContentSize: size))
        }
        boardView.applyFontScale()
        quotaWidth?.constant = QuotaLayout.panelWidth
        quota.render(
            gauges: QuotaProjection.gauges(from: quotaSources), cards: cards,
            claudeProfiles: agentAccountStore.profiles,
            claudeProfileByCard: claudeProfileByCardMap())
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// Fit the board to the window shape: auto-shrink the type on narrow windows
    /// and dock the quota panel under the board on portrait ones. The scale is
    /// quantized in ``BoardTheme/responsiveScale(forContentWidth:)`` and the dock
    /// only changes by whole quota cards, so a live resize drag only pays for a
    /// scaffold rebuild when it crosses a step.
    private func applyResponsiveLayout() {
        guard let size = window?.contentView?.frame.size else { return }
        let dock = QuotaLayout.dock(forContentSize: size)
        // A bottom-docked panel hands its column back to the board, so the board is
        // as wide as it would be in a window that much wider.
        let boardGain = dock == .trailing ? 0 : QuotaLayout.panelWidth
        let scale = BoardTheme.responsiveScale(forContentWidth: size.width + boardGain)
        guard scale != BoardTheme.responsiveFontScale || dock != quota.dock else { return }
        BoardTheme.responsiveFontScale = scale
        reflowBoardTypography()
    }

    public func windowDidResize(_ notification: Notification) {
        applyResponsiveLayout()
    }

    private func changeTerminalFont(by delta: CGFloat) {
        terminalFontSize = min(28, max(12, terminalFontSize + delta))
        drillIn.updateTerminalFontSize(terminalFontSize)
    }

    /// The add-task affordance (⌘N): open the keyboard-first create palette —
    /// project → harness → task — replacing the old NSAlert + bare chooser. A card is a
    /// *task* the operator is working on, not an anonymous `terminal-N`; naming it at
    /// birth is what makes the board legible. Cancelling creates nothing.
    func promptAndCreateSession() { openCreatePalette() }

    /// Mount ``CreateCardPalette`` full-window and wire its confirm closures to the
    /// card-creation logic (which owns the pool firewall + binding invariants).
    /// The palette is a dumb view; every side effect flows back through here.
    func openCreatePalette() {
        let palette = CreateCardPalette(
            recents: paletteRecents(), agentAccounts: agentAccountStore.accounts)
        palette.browse = { [weak self] in Self.chooseFolder(relativeTo: self?.window) }
        palette.onCancel = { [weak self] in self?.dismissCreatePalette() }
        palette.addAgentAccount = { [weak self] agent in
            self?.promptAddAgentAccount(agent: agent, from: palette)
        }
        palette.confirmInteractive = { [weak self] (title: String, dir: String,
                                                    harness: CreateCardPalette.Harness,
                                                    inWorktree: Bool, profileID: UUID?) in
            guard let self else { return }
            let accountID = AgentAccountBackend.supportsMultiAccount(harness.cardAgent ?? .claude)
                ? profileID : nil
            self.createSession(
                title: title.isEmpty ? nil : title, projectDir: dir,
                autoStartAgent: harness.cardAgent, inWorktree: inWorktree,
                claudeProfileID: accountID)
            self.rememberProjectDir(dir)
            self.dismissCreatePalette()
        }
        palette.windowsHosts = windowsRemoteHosts
        palette.confirmRemote = { [weak self] title, destination, dir, windows in
            self?.completeRemoteCard(
                title: title, destination: destination, dir: dir, windows: windows)
        }
        createPalette?.removeFromSuperview()
        createPalette = palette
        guard let root = boardView.superview else { return }
        layoutFullWindow(palette, in: root)
        palette.focusStage()
    }

    /// The palette's remote path (US-009 AC-3). It parses the SAME spec and calls the
    /// SAME ``createRemoteTmuxSession(spec:)`` the ⌘⇧R alert used, so a palette card and
    /// an alert card are one construction — identical argv, identity binding and restore
    /// snapshot. Returns an error string for the palette to show, nil once the card exists.
    private func completeRemoteCard(
        title: String, destination: String, dir: String, windows: Bool
    ) -> String? {
        let folder = dir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var spec = RemoteTmuxSpec.parse(destination: destination, sessionName: title,
                                              remoteDir: folder.isEmpty ? nil : folder) else {
            return "Enter a host — e.g. you@box or box:2222."
        }
        spec.hostKind = windows ? .windowsPsmux : .posix
        guard createRemoteTmuxSession(spec: spec) != nil else {
            return lastRemoteSessionIssue?.description ?? "Could not open the remote session."
        }
        if !folder.isEmpty { recentFolders.remember(host: destination, path: folder) }
        rememberWindowsHost(destination, isWindows: windows)
        dismissCreatePalette()
        return nil
    }

    /// Hosts the operator marked "Windows (psmux)": pre-checks the palette toggle the
    /// next time that host is picked. Keyed by the typed destination string — the same
    /// token the recents store and the palette's host rows use. Lives in the same
    /// defaults as the recents so a test's scratch suite isolates both.
    private var windowsRemoteHosts: Set<String> {
        Set(recentFoldersDefaults.stringArray(forKey: Self.windowsHostsKey) ?? [])
    }

    private func rememberWindowsHost(_ host: String, isWindows: Bool) {
        var hosts = windowsRemoteHosts
        if isWindows { hosts.insert(host) } else { hosts.remove(host) }
        recentFoldersDefaults.set(hosts.sorted(), forKey: Self.windowsHostsKey)
    }

    static let windowsHostsKey = "sich.remote.windowsHosts"

    func dismissCreatePalette() {
        createPalette?.removeFromSuperview()
        createPalette = nil
        window?.makeFirstResponder(boardView)
    }

    /// Add a named agent account (isolated config root + hooks + optional sign-in).
    private func promptAddAgentAccount(
        agent: CardAgent? = nil, host: String? = nil, from palette: CreateCardPalette? = nil
    ) {
        let kind = agent ?? .claude
        let alert = NSAlert()
        alert.messageText = "Add \(AgentAccountBackend.displayName(for: kind)) Account"
        alert.informativeText = """
            Each account uses its own config directory (credentials + settings). \
            Sich can open a sign-in terminal after you add the account.
            """
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(frame: NSRect(x: 0, y: 62, width: 320, height: 24))
        name.placeholderString = "Account name (e.g. Work)"
        let dir = NSTextField(frame: NSRect(x: 0, y: 34, width: 320, height: 24))
        dir.placeholderString = "Config dir (optional — a name is enough)"
        let hostField = NSTextField(frame: NSRect(x: 0, y: 6, width: 320, height: 24))
        hostField.placeholderString = "Host (blank = this Mac; user@box for remote)"
        hostField.stringValue = host ?? ""
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 86))
        box.addSubview(name)
        box.addSubview(dir)
        box.addSubview(hostField)
        alert.accessoryView = box
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let configPath = dir.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = configPath.isEmpty
            ? AgentAccountBackend.suggestedConfigRoot(agent: kind, name: trimmed) : configPath
        let hostValue = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountHost = hostValue.isEmpty ? nil : hostValue
        let account = agentAccountStore.add(
            name: trimmed, agent: kind, configRoot: resolved, host: accountHost)
        if accountHost == nil {
            _ = HookInstaller.provisionAccount(account)
        } else if let spec = RemoteTmuxSpec.parse(destination: accountHost!, sessionName: "sich-auth") {
            _ = HookInstaller.installRemoteAccount(
                spec: spec, account: account, runner: remoteSessionRunner)
        }
        restartQuotaPoller()
        if let palette {
            palette.reloadAgentAccounts(agentAccountStore.accounts)
            palette.selectAgentAccount(account.id)
        }
        refresh()
        offerAccountSignIn(account)
    }

    private func offerAccountSignIn(_ account: AgentAccountProfile) {
        guard account.authStatus != .ready else { return }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(account.name)?"
        alert.informativeText = """
            Opens a short-lived terminal card and runs the agent's login command. \
            Complete browser auth there, then return to the board.
            """
        alert.addButton(withTitle: "Sign In Now")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startAccountSignIn(account)
    }

    /// Guided auth: a dedicated card with the right env vars and login keystrokes.
    private func startAccountSignIn(_ account: AgentAccountProfile) {
        if let host = account.host, let spec = RemoteTmuxSpec.parse(destination: host, sessionName: "sich-signin-\(account.id.uuidString.prefix(8))") {
            _ = HookInstaller.installRemoteAccount(spec: spec, account: account, runner: remoteSessionRunner)
            let cardID = UUID()
            let env = AgentAccountBackend.remoteTmuxEnvironment(for: account)
            guard let seed = try? BoardSeed.remoteTmux(
                spec: spec, title: "Sign in: \(account.name)", cardID: cardID.uuidString,
                agent: account.agent, tmuxEnvironment: env),
                  let session = launch(seed) else { return }
            let card = BoardCard(
                id: cardID, sessionID: seed.sessionID, title: seed.title,
                projectDir: seed.projectDir, agent: account.agent, state: .idle)
            cards.append(card)
            ptyByCard[card.id] = session.pty
            taskMetaByCard[card.id] = CardTaskMeta(remote: spec, claudeProfileID: account.id)
            TmuxControlBridge.attachIfNeeded(to: session)
            session.pty.sendWhenReady(Array(AgentAccountBackend.loginCommand(for: account, localShim: false).utf8))
            RemoteHookStatus.shared.register(spec)
            sessionsPoller?.attachRemoteHost(spec)
            refresh()
            persistTasks()
            return
        }
        let dir = RepoLocator.launchProjectDir(repoRoot: repoRoot)
        guard let card = createSession(
            title: "Sign in: \(account.name)", projectDir: dir, autoStartAgent: nil,
            claudeProfileID: account.id) else { return }
        guard let pty = ptyByCard[card.id] else { return }
        switch account.agent {
        case .codex: HookInstaller.installCodexShim()
        case .cursor: HookInstaller.installCursorHooks()
        default: break
        }
        _ = pty.send(Array(AgentAccountBackend.loginCommand(for: account, localShim: true).utf8))
        agentAccountStore.refreshAuthStatus(id: account.id)
        refresh()
    }

    /// List and remove named agent accounts.
    private func promptManageAgentAccounts() {
        let list = agentAccountStore.accounts.map {
            let scope = $0.host.map { " · \($0)" } ?? ""
            let auth = $0.authStatus == .ready ? " ✓" : ($0.authStatus == .pending ? " · sign-in pending" : "")
            return "\(AgentAccountBackend.displayName(for: $0.agent)) · \($0.name) (\($0.configRoot))\(scope)\(auth)"
        }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Agent Accounts"
        alert.informativeText = list.isEmpty ? "No accounts configured." : list
        alert.addButton(withTitle: "Add Account…")
        alert.addButton(withTitle: "Remove…")
        alert.addButton(withTitle: "Done")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            promptPickAgentKindForAdd()
        case .alertSecondButtonReturn:
            promptRemoveAgentAccount()
        default:
            break
        }
    }

    private func promptPickAgentKindForAdd() {
        let alert = NSAlert()
        alert.messageText = "Which agent?"
        alert.informativeText = "Pick the LLM client this account is for."
        alert.addButton(withTitle: "Claude")
        alert.addButton(withTitle: "Codex")
        alert.addButton(withTitle: "Cursor")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: promptAddAgentAccount(agent: .claude)
        case .alertSecondButtonReturn: promptAddAgentAccount(agent: .codex)
        case .alertThirdButtonReturn: promptAddAgentAccount(agent: .cursor)
        default: break
        }
    }

    private func promptRemoveAgentAccount() {
        let removable = agentAccountStore.accounts.filter { !$0.isDefault }
        guard !removable.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove Agent Account"
        alert.informativeText = "Cards already bound keep their account id; only the picker list changes."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        for account in removable {
            popup.addItem(withTitle: "\(AgentAccountBackend.displayName(for: account.agent)) · \(account.name)")
        }
        alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let account = removable[popup.indexOfSelectedItem]
        agentAccountStore.remove(id: account.id)
        restartQuotaPoller()
        refresh()
    }

    /// Recent project dirs as palette rows, each tagged with how many owned (live-pty)
    /// cards currently run in it — the "N active cards" the design shows.
    /// Local rows carry their active-card count; remote rows deliberately don't — a
    /// far-side folder can hold sessions this board doesn't own, so any number would
    /// be a guess. Host-qualification comes straight from the store (US-009 AC-2).
    private func paletteRecents() -> [PaletteProject] {
        var active: [String: Int] = [:]
        for card in cards where ptyByCard[card.id] != nil {
            active[Self.normDir(card.projectDir), default: 0] += 1
        }
        let local = recentProjectDirs().map {
            PaletteProject(host: nil, path: $0, activeCards: active[Self.normDir($0)] ?? 0)
        }
        return local + recentFolders.load().filter { $0.host != nil }
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
        let root = RepoLocator.launchProjectDir(repoRoot: repoRoot)
        var dirs = recentFolders.load().filter { $0.host == nil }.map(\.path)
        if !dirs.contains(root) { dirs.append(root) }
        return dirs
    }

    /// Push a dir to the front of the MRU list. The store owns dedup, the per-host cap
    /// and the legacy plain-`[String]` migration; this just says "local".
    private func rememberProjectDir(_ dir: String) {
        recentFolders.remember(host: nil, path: dir)
    }

    /// The one host-qualified recents store the palette reads and both create paths
    /// write (US-009 AC-2). ponytail: UserDefaults is the stdlib MRU store.
    private var recentFolders: RecentFolderStore {
        RecentFolderStore(defaults: recentFoldersDefaults, key: Self.recentDirsKey)
    }

    /// Which defaults that store reads and writes. Production is `.standard`; a test
    /// points it at a scratch suite so a run never touches the operator's real MRU.
    var recentFoldersDefaults: UserDefaults = .standard

    static let recentDirsKey = "sich.recentProjectDirs"

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
        inWorktree: Bool = false,
        claudeProfileID: UUID? = nil
    ) -> BoardCard? {
        sessionCounter += 1
        let chosen = (projectDir?.isEmpty == false) ? projectDir : nil
        var dir = chosen.map { ($0 as NSString).expandingTildeInPath }
            ?? RepoLocator.launchProjectDir(repoRoot: repoRoot)
        if inWorktree,
           let worktree = worktreeProvisioner.provision(repoDir: dir, slug: sessionSlug(title)) {
            // The card LIVES in its own checkout on a fresh task/<slug> branch, so
            // parallel tasks on one repo stop stepping on each other's working tree.
            // A non-repo dir (or git failure) falls through to the chosen dir — the
            // worktree is an upgrade, never a gate on creating the card.
            dir = worktree.path
        }
        // The card id is minted BEFORE launch so it can ride the pty environment
        // (SICH_CARD_ID) — the identity binding that folds the hook-observed
        // claude session back into this card even when the repo dir is shared.
        let cardID = UUID()
        let agent = autoStartAgent ?? .claude
        let profileID = AgentAccountBackend.supportsMultiAccount(agent)
            ? (claudeProfileID ?? agentAccountStore.selectable(for: agent, host: nil).first?.id) : nil
        let seed = BoardSeed.liveTerminal(
            projectDir: dir, sessionID: sessionSlug(title), title: title,
            cardID: cardID.uuidString, agent: agent,
            accountEnv: accountEnvExports(for: profileID, agent: agent)
        )
        guard let session = launch(seed) else { return nil }
        let card = BoardCard(
            id: cardID,
            sessionID: seed.sessionID, title: seed.title, projectDir: seed.projectDir,
            agent: seed.agent, state: seed.state
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
            _ = session.pty.send(Array(Self.startClaudeCommand(sessionID: session.id, via: .localShim).utf8))
        } else if autoStartAgent == .codex {
            HookInstaller.installCodexShim()
            _ = session.pty.send(Array(Self.startCodexCommand().utf8))
        } else if autoStartAgent == .cursor {
            HookInstaller.installCursorHooks()
            _ = session.pty.send(Array(Self.startCursorCommand().utf8))
        } else if autoStartAgent == .antigravity {
            HookInstaller.installAntigravityHooks()
            _ = session.pty.send(Array(Self.startAntigravityCommand().utf8))
        }
        if taskMetaByCard[card.id] == nil {
            taskMetaByCard[card.id] = CardTaskMeta(claudeProfileID: profileID)
        } else if let profileID {
            taskMetaByCard[card.id]?.claudeProfileID = profileID
        }
        refresh()
        persistTasks()
        return card
    }

    /// Open a REMOTE terminal card: SSH into `spec.host` and attach to (or create) a
    /// tmux session there. Mirrors ``createSession`` but skips the local-only steps
    /// (worktree, cwd reporting, auto-`claude`) — a remote card has no local checkout,
    /// and the human drives the far-side session themselves. Firewall-clean (the launched
    /// binary is `ssh`). The model mutation is split from any prompt so tests can drive it.
    @discardableResult
    func createRemoteTmuxSession(spec: RemoteTmuxSpec) -> BoardCard? {
        let cardID = UUID()
        let spec = named(spec, forCard: cardID)
        lastRemoteSessionIssue = nil
        guard let key = try? RemoteSessionKey.make(for: spec) else { return nil }
        if let issue = remoteSessionConflict(for: key, cardID: cardID.uuidString, spec: spec) {
            lastRemoteSessionIssue = issue
            return nil
        }
        sessionCounter += 1
        // A brand-new card lands in a brand-new tmux session — a bare login shell,
        // which is not what anyone opened a card for. Start the agent the way the
        // local flow does, pinned to a conversation id minted BEFORE the argv exists:
        // interactive `claude`, never `claude -p`, riding the session's own launch
        // command on the far side (see `RemoteTmuxCommand.argv`). Structurally
        // safe: `.foreign` was refused above and no far-side session can be `.bound`
        // to an id minted this very call, so `-A` creates rather than attaches.
        let conversation = UUID()
        guard let seed = try? BoardSeed.remoteTmux(
            spec: spec, cardID: cardID.uuidString,
            agentCommand: RemoteTmuxCommand.claudeStart(sessionID: conversation)),
              let session = launch(seed) else { return nil }
        let card = BoardCard(
            id: cardID,
            sessionID: seed.sessionID, title: seed.title, projectDir: seed.projectDir,
            agent: seed.agent, state: seed.state
        )
        cards.append(card)
        ptyByCard[card.id] = session.pty
        // The spec, not the argv: this is what a quit persists and the next launch
        // rebuilds the same attach from (US-006). It lives on the card's meta too,
        // so the every-mutation task book carries it even if the session dies.
        taskMetaByCard[card.id] = CardTaskMeta(remote: spec)
        // Same project, other machine: the remote dir's trailing name links this
        // card's hue to the local checkout of the same project.
        BoardTheme.linkProject(card: card.id, toDirectory: spec.remoteDir)
        session.recordRemoteSpec(spec)
        // The card attaches in tmux CONTROL MODE: the bridge decodes the wire
        // protocol into pane bytes (local scrollback, smooth wheel, prompt jumps)
        // while ssh's password prompt still passes through untouched.
        TmuxControlBridge.attachIfNeeded(to: session)
        session.recordClaudeSession(conversation)
        // Learn this host's hook state so the card's chip can say something true
        // about it (US-005). Inert unless the real executable enabled probing.
        RemoteHookStatus.shared.register(spec)
        // Follow that host's event log from now on, so hooks fired on the far side
        // reach this board (US-003). Idempotent per host; inert unless the real
        // executable enabled spawning.
        sessionsPoller?.attachRemoteHost(spec)
        refresh()
        persistTasks()
        return card
    }

    /// An unnamed card gets a name derived from its own id (US-004 AC-4): with one
    /// shared default, `-A` attached every unnamed card to the SAME remote session.
    private func named(_ spec: RemoteTmuxSpec, forCard cardID: UUID) -> RemoteTmuxSpec {
        guard RemoteTmuxCommand.sanitizeSessionName(spec.sessionName).isEmpty else { return spec }
        var named = spec
        named.sessionName = RemoteTmuxCommand.defaultSessionName(for: cardID)
        return named
    }

    /// Whether `(host, sanitized name)` is already taken — on this board, or on the
    /// far side by a session Sich did not create. Both cases would make `-A` attach
    /// rather than create, so the pane's binding would be somebody else's (or none).
    ///
    /// Silence from the far side is `unknown`, never a refusal: an unreachable host
    /// must not make remote cards unopenable.
    private func remoteSessionConflict(
        for key: RemoteSessionKey, cardID: String, spec: RemoteTmuxSpec
    ) -> RemoteSessionIssue? {
        if cards.contains(where: { RemoteSessionKey.parse(sessionID: $0.sessionID) == key }) {
            return .duplicateCard(key)
        }
        let presence = RemoteSessionProbe.presence(
            of: key, cardID: cardID, spec: spec, runner: remoteSessionRunner)
        return presence == .foreign ? .foreignSession(key) : nil
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

    // MARK: - Backlog (durable tasks that have no session yet)

    /// Add a task to the backlog: pure durable intent — title + description, no
    /// session, no pty. Written through the task store immediately, so it survives
    /// a crash one line later.
    @discardableResult
    func addBacklogTask(title: String, details: String = "", projectDir: String? = nil) -> TaskRecord {
        let record = TaskRecord(
            id: UUID(), title: title, details: details, placement: .backlog,
            projectDir: projectDir
        )
        backlogTasks.append(record)
        persistTasks()
        refresh()
        return record
    }

    /// Edit a backlog task in place (`nil` leaves a field unchanged).
    func updateBacklogTask(id: UUID, title: String? = nil, details: String? = nil) {
        guard let idx = backlogTasks.firstIndex(where: { $0.id == id }) else { return }
        if let title { backlogTasks[idx].title = title }
        if let details { backlogTasks[idx].details = details }
        persistTasks()
        refresh()
    }

    func deleteBacklogTask(id: UUID) {
        guard backlogTasks.contains(where: { $0.id == id }) else { return }
        backlogTasks.removeAll { $0.id == id }
        persistTasks()
        refresh()
    }

    /// Pull open Notion tasks assigned to the operator into the backlog: once at
    /// launch, then every 10 minutes. No importer (no token) → no-op.
    private func startNotionImport() {
        guard notionImporter != nil else { return }
        pullNotionTasks()
        let timer = Timer(timeInterval: 10 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullNotionTasks() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pullNotionTasks() {
        guard let notionImporter else { return }
        Task { [weak self] in
            let fresh = await notionImporter.pull()
            for task in fresh {
                self?.addBacklogTask(title: task.title, details: task.backlogDetails)
            }
        }
    }

    /// Move a backlog task onto the board with an explicit launch choice — the agent
    /// (Claude/Codex/Cursor/Antigravity). On success the
    /// task leaves the backlog and its description rides along on the new card's
    /// durable record; a failed launch leaves the backlog untouched, so a task is
    /// never lost to a spawn error.
    @discardableResult
    func promoteBacklogTask(
        id: UUID, agent: CardAgent = .claude, inWorktree: Bool = false
    ) -> BoardCard? {
        guard let idx = backlogTasks.firstIndex(where: { $0.id == id }) else { return nil }
        let record = backlogTasks[idx]
        guard let card = createSession(
            title: record.title, projectDir: record.projectDir,
            autoStartAgent: agent, inWorktree: inWorktree
        ) else { return nil }
        backlogTasks.remove(at: idx)
        // The card id supersedes the backlog id, but the task's description and
        // original creation time survive the promotion on the card's record.
        taskMetaByCard[card.id] = CardTaskMeta(
            details: record.details, createdAt: record.createdAt
        )
        persistTasks()
        refresh()
        return card
    }

    /// The "+ backlog task" prompt: title + free-form description. The model
    /// mutation is ``addBacklogTask`` so tests drive it without the modal.
    private func promptAddBacklogTask() {
        let alert = NSAlert()
        alert.messageText = "New Backlog Task"
        alert.informativeText = "Saved durably now; start it later with the agent of your choice."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let title = NSTextField(frame: NSRect(x: 0, y: 38, width: 300, height: 24))
        title.placeholderString = "Task title"
        let details = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        details.placeholderString = "Description (optional)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 62))
        box.addSubview(title)
        box.addSubview(details)
        alert.accessoryView = box
        alert.window.initialFirstResponder = title
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = title.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        addBacklogTask(title: trimmed, details: details.stringValue)
    }

    /// The "start task" chooser for a backlog card: pick the agent, then
    /// promote through the same model API tests use. Returns the new board card,
    /// or nil on cancel / failed launch — the page uses this to decide whether to
    /// follow the task back to the board.
    @discardableResult
    private func promptPromoteBacklogTask(_ record: TaskRecord) -> BoardCard? {
        let alert = NSAlert()
        alert.messageText = "Start \(record.title)"
        alert.informativeText = record.details.isEmpty ? "Choose how to run this task." : record.details
        alert.addButton(withTitle: "Claude")
        alert.addButton(withTitle: "Codex")
        alert.addButton(withTitle: "Cursor")
        alert.addButton(withTitle: "Antigravity")
        alert.addButton(withTitle: "Cancel")
        // Buttons past the third answer with 1000 + index (AppKit's numbering).
        let cursorButton = NSApplication.ModalResponse(rawValue: 1003)
        let antigravityButton = NSApplication.ModalResponse(rawValue: 1004)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return promoteBacklogTask(id: record.id, agent: .claude)
        case .alertSecondButtonReturn: return promoteBacklogTask(id: record.id, agent: .codex)
        case cursorButton: return promoteBacklogTask(id: record.id, agent: .cursor)
        case antigravityButton: return promoteBacklogTask(id: record.id, agent: .antigravity)
        default: return nil
        }
    }

    // MARK: - Backlog page (retained internally while its UI is hidden)

    /// Swap the board chrome for the backlog page. Kept for backlog behavior tests
    /// and future re-exposure; no production control currently calls this entry.
    // periphery:ignore - deliberate retention while the backlog UI is hidden (see doc above)
    func showBacklogPage() {
        backlogPage.render(backlogTasks)
        boardView.isHidden = true
        quota.isHidden = true
        backlogPage.isHidden = false
        window?.makeFirstResponder(backlogPage)
    }

    /// Esc / "← board" / a successful promote: restore the board exactly as left.
    func hideBacklogPage() {
        backlogPage.isHidden = true
        boardView.isHidden = false
        quota.isHidden = false
        refresh()
        window?.makeFirstResponder(boardView)
    }

    // MARK: - Archive page (the DONE column's history)

    /// Swap the board chrome for the archive ledger (the archive icon beside DONE).
    func showArchivePage() {
        archivePage.render(archivedTasks)
        boardView.isHidden = true
        quota.isHidden = true
        archivePage.isHidden = false
        window?.makeFirstResponder(archivePage)
    }

    /// Put an archived task back on the board and open its session. Lands in idle
    /// (a revived task is in play again — DONE would close the terminal and the
    /// next launch would archive it before it could be read). Local cards resume
    /// the pinned conversation in their directory; remote cards re-attach over ssh.
    /// The same ``reviveSession(for:)`` path a DONE → in-play move already uses.
    @discardableResult
    func reviveArchivedTask(id: UUID) -> BoardCard? {
        guard let index = archivedTasks.firstIndex(where: { $0.id == id }) else { return nil }
        let record = archivedTasks.remove(at: index)
        adoptBoardRecord(record, state: .idle)
        restoreRevivedCard(id)
        persistTasks()
        guard let card = cards.first(where: { $0.id == id }) else { return nil }
        // Stay on the archive while the attach runs (a remote probe can take a
        // moment). The drill-in takes over when the session is back; if it cannot
        // (the checkout is gone), the card is still on the board to be found.
        drill(into: card)
        if drillIn.isHidden { hideArchivePage() }
        return cards.first { $0.id == id }
    }

    /// A revived card is back in play: not a durable DONE, so the next launch
    /// keeps it on the board instead of sweeping it into the archive again.
    private func restoreRevivedCard(_ id: UUID) {
        manuallyDoneCardIDs.remove(id)
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index] = cards[index].with(state: .idle)
    }

    /// Esc / "← board": restore the board exactly as left.
    func hideArchivePage() {
        archivePage.isHidden = true
        boardView.isHidden = false
        quota.isHidden = false
        refresh()
        window?.makeFirstResponder(boardView)
    }

    /// A card was dragged to another column → set its state to that column's state
    /// (a manual lifecycle override). Identity is preserved; the PTY is too, with one
    /// exception: DONE closes the terminal (a finished task must stop eating a shell,
    /// an fd, and a pump slot), after freezing its resume hints. Leaving DONE brings
    /// the terminal back on the SAME conversation via ``reviveSession(for:)``.
    /// Rule 1: park off NEEDS YOU until tomorrow and persist the snooze.
    func deferNeedsYouToTomorrow(cardID: UUID, now: Date = Date()) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        let until = NeedsYouStandup.defaultDeferUntil(from: now)
        let card = cards[idx]
        workLog?.noteEvent(
            "parked until \(Self.standupStamp.string(from: until)) (NEEDS YOU standup)",
            card: card, at: now)
        // The snooze is stamped AFTER the move: landing in PARKED clears any existing
        // deferral, which would otherwise wipe the one this call exists to record.
        move(cardID: cardID, to: .parked)
        taskMetaByCard[cardID, default: CardTaskMeta()].needsYouDeferredUntil = until
        persistTasks()
    }

    func move(cardID: UUID, to column: BoardColumn) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        let wasDone = cards[idx].state == .done
        cards[idx] = cards[idx].with(state: column.state)
        if column == .parked || column == .idle || column == .blocked {
            taskMetaByCard[cardID]?.needsYouDeferredUntil = nil
        }
        if column == .blocked || column == .parked {
            operatorHeldCardIDs.insert(cardID)
        } else {
            operatorHeldCardIDs.remove(cardID)
        }
        if column == .done {
            manuallyDoneCardIDs.insert(cardID)
            closeTerminal(for: cardID)
        } else {
            manuallyDoneCardIDs.remove(cardID)
            if wasDone, ptyByCard[cardID] == nil {
                // DONE → back in play: resume the terminal eagerly so the card is
                // live again the moment it lands, not on the next drill-in. The
                // revival carries the conversation id captured at close time.
                _ = reviveSession(for: cards[idx])
            }
        }
        refresh()
        persistTasks()
    }

    /// Checklist 18.08: "when the task is DONE → close terminal, so we don't eat
    /// resources." Captures resume hints first — the one moment the session can still
    /// be read — so a later DONE → IN PROGRESS move (or drill-in) revives the same
    /// Claude conversation. The session leaves the registry so neither the pump, the
    /// dead-session reconcile, nor the quit snapshot keeps a finished task alive.
    private func closeTerminal(for cardID: UUID) {
        guard let pty = ptyByCard[cardID] else { return }
        captureResumeHints(for: cardID)
        ptyByCard.removeValue(forKey: cardID)
        if let session = registry.all.first(where: { $0.pty === pty }) {
            registry.remove(id: session.id)
        }
        pty.terminate()
        deadCardIDs.remove(cardID)
    }

    /// Rename a card in place — identity, state, and PTY binding all preserved (the
    /// mutator keeps `id`), so renaming a live task never disturbs its session. An
    /// empty title clears back to the project-dir fallback.
    func rename(cardID: UUID, to newTitle: String?) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[idx] = cards[idx].with(title: newTitle)
        refresh()
        persistTasks()
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
        codexChoiceWaitingCardIDs.remove(cardID)
        lastCardStates.removeValue(forKey: cardID)
        taskMetaByCard.removeValue(forKey: cardID)
        seededCardIDs.remove(cardID)
        manuallyDoneCardIDs.remove(cardID)
        operatorHeldCardIDs.remove(cardID)
        refresh()
        persistOnTerminate(store: SessionSnapshotStore.applicationSupport())
        persistTasks()
    }

    /// US-002: drill into a card → full-window terminal takeover (Altitude-1).
    /// The board surface and quota panel are hidden so the embedded terminal
    /// is the only thing on screen.
    func drill(into card: BoardCard) {
        guard let pty = ptyByCard[card.id] ?? reviveSession(for: card) else { return }
        noteFocus(card.id)
        workLog?.noteUserEntered(card)
        selection.focus(card.id)
        drilledInCardID = card.id   // its surface owns the fd now; the pump skips it
        boardView.isHidden = true
        backlogPage.isHidden = true
        archivePage.isHidden = true
        quota.isHidden = true
        drillIn.isHidden = false
        drillIn.focus(card: card, pty: pty, terminalFontSize: terminalFontSize)
        drillIn.updateQuota(QuotaProjection.gauges(from: quotaSources))
    }

    /// A session-less card — the task book outlived its shell (crash, upgrade, or a
    /// data migration) — comes back to life on first drill-in: its login shell
    /// relaunches in the durable project dir under the ORIGINAL card id (so hook
    /// lines keep binding to this card), and a pinned Claude conversation resumes
    /// instead of restarting. Firewall-clean: a login shell plus interactive
    /// `claude --resume`, never `claude -p`. Returns nil when the recorded dir no
    /// longer exists locally (e.g. a remote card's `user@host` label) — the click
    /// stays inert rather than stranding a dead shell on the board.
    private func reviveSession(for card: BoardCard) -> PTYSession? {
        // A remote card revives by RE-ATTACHING over ssh — before the local-dir
        // guard, which its `user@host` label could never pass.
        if let spec = remoteSpec(for: card) {
            return reviveRemoteSession(spec: spec, card: card)
        }
        let hint = taskMetaByCard[card.id]?.sessionRef
        let dir = hint?.lastCwd ?? card.projectDir
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        let profileID = taskMetaByCard[card.id]?.claudeProfileID
        let seed = BoardSeed.liveTerminal(
            projectDir: dir, sessionID: card.sessionID, title: card.title,
            cardID: card.id.uuidString, agent: card.agent,
            accountEnv: accountEnvExports(for: profileID, agent: card.agent)
        )
        guard let session = launch(seed) else { return nil }
        if let resumeID = hint?.claudeSessionID {
            // Carry the ORIGINAL conversation id forward, same as openRestoredCard:
            // the resume token must survive an unbounded chain of revivals.
            session.recordClaudeSession(resumeID)
            _ = session.pty.send(Array(Self.resumeClaudeCommand(sessionID: resumeID, via: .localShim).utf8))
        } else if card.agent == .codex {
            HookInstaller.installCodexShim()
            _ = session.pty.send(Array(Self.resumeCodexCommand().utf8))
        } else if card.agent == .cursor {
            HookInstaller.installCursorHooks()
            _ = session.pty.send(Array(Self.resumeCursorCommand().utf8))
        } else if card.agent == .antigravity {
            HookInstaller.installAntigravityHooks()
            _ = session.pty.send(Array(Self.resumeAntigravityCommand().utf8))
        }
        ptyByCard[card.id] = session.pty
        persistTasks()
        return session.pty
    }

    /// The spec a revival rebuilds the attach from: the durable meta, or a recovery
    /// from the card's own id — with the start directory refreshed to wherever the far
    /// side was last seen working.
    private func remoteSpec(for card: BoardCard) -> RemoteTmuxSpec? {
        guard var spec = taskMetaByCard[card.id]?.remote ?? recoveredRemoteSpec(for: card)
        else { return nil }
        // Start where the operator actually WAS, not where the card was created: the
        // last cwd the far side reported. Only matters when tmux has to create the
        // session (it ignores `-c` on an attach), which is exactly the case this is
        // for — the far side lost the session and the card must rebuild the context.
        if let observed = taskMetaByCard[card.id]?.sessionRef?.lastCwd, observed.hasPrefix("/") {
            spec.remoteDir = observed
        }
        return spec
    }

    /// For books written before the spec was persisted: a best-effort parse of the
    /// card's own `(host, session)` id and `user@host` label. A recovered spec may lose
    /// a custom port; the next save persists the full spec going forward.
    private func recoveredRemoteSpec(for card: BoardCard) -> RemoteTmuxSpec? {
        guard let key = RemoteSessionKey.parse(sessionID: card.sessionID) else { return nil }
        return RemoteTmuxSpec.parse(destination: card.projectDir, sessionName: key.session)
            ?? RemoteTmuxSpec(host: key.host, sessionName: key.session)
    }

    /// Re-attach a session-less remote card under the ORIGINAL card id.
    ///
    /// Normally tmux kept the far side exactly as the operator left it and revival is a
    /// pure attach: nothing is started, because it would talk over whatever is already
    /// running there. But `-A` also silently CREATES the session when the far side lost
    /// it (a reboot, an OOM sweep, a killed tmux server) — and that case used to be
    /// indistinguishable from a resume, so the operator landed on a bare login shell
    /// with their conversation stranded. So ask first: only when the far side says the
    /// session is gone do we rebuild the context we know about — the last directory,
    /// via the spec, and the conversation, by resuming it on the session's own launch
    /// command (the create branch of `-A`, exactly the case this is for).
    private func reviveRemoteSession(spec: RemoteTmuxSpec, card: BoardCard) -> PTYSession? {
        let lost = remoteSessionIsLost(spec: spec, cardID: card.id.uuidString)
        let rebuild = lost ? remoteRebuild(for: card) : nil
        guard let seed = try? BoardSeed.remoteTmux(
            spec: spec, sessionID: card.sessionID, title: card.title,
            cardID: card.id.uuidString, agent: card.agent,
            agentCommand: rebuild?.command
        ), let session = launch(seed) else { return nil }
        adoptRestoredRemote(spec, on: session)
        if let rebuild {
            session.recordClaudeSession(rebuild.conversation)
        }
        ptyByCard[card.id] = session.pty
        persistTasks()
        return session.pty
    }

    /// What a tmux session the far side had to build from nothing runs, to put the card
    /// back on a conversation instead of an empty prompt.
    ///
    /// With a known conversation id it is a resume; without one — the far side was lost
    /// before any hook line named it — it is a fresh conversation PINNED to an id we
    /// mint here, exactly as the local create path does, so this card is resumable the
    /// next time the far side drops it. Either way the session records the id, so it
    /// survives an unbounded chain of losses.
    ///
    /// Claude cards only. Codex resume runs through a locally-installed shim that does
    /// not exist on the far side, and Gemini has no resume; both come back to the shell
    /// prompt they left, which is what the operator can act on.
    /// Firewall-clean throughout: interactive `claude`, never `claude -p`.
    private func remoteRebuild(for card: BoardCard) -> (command: String, conversation: UUID)? {
        guard card.agent == .claude else { return nil }
        if let resumeID = taskMetaByCard[card.id]?.sessionRef?.claudeSessionID {
            return (RemoteTmuxCommand.claudeResume(sessionID: resumeID), resumeID)
        }
        let fresh = UUID()
        return (RemoteTmuxCommand.claudeStart(sessionID: fresh), fresh)
    }

    /// Whether the far side has LOST this card's tmux session, so the attach about to
    /// run will really be a create. Only a definite `absent` counts: an unreachable or
    /// silent host answers `unknown`, and typing a resume into a session that turns out
    /// to be alive is the one outcome worse than not resuming at all.
    private func remoteSessionIsLost(spec: RemoteTmuxSpec, cardID: String) -> Bool {
        guard let key = try? RemoteSessionKey.make(for: spec) else { return false }
        return RemoteSessionProbe.presence(
            of: key, cardID: cardID, spec: spec, runner: remoteSessionRunner) == .absent
    }

    /// US-002 AC#2: return to the board, state preserved — un-hide the board so it
    /// looks exactly as it did before drilling in.
    func returnToBoard() {
        if let inside = drilledInCardID,
           let card = cards.first(where: { $0.id == inside }) {
            workLog?.noteUserLeft(card)
        }
        selection.returnToBoard()
        // A card whose child died while drilled in was left up so the operator could
        // read the end banner; leaving it now is the moment it comes off the board.
        if let dead = drilledInCardID, deadCardIDs.contains(dead) { removeDeadCard(dead) }
        drilledInCardID = nil   // surface is detaching; the pump resumes draining this fd
        boardView.isHidden = false
        backlogPage.isHidden = true
        archivePage.isHidden = true
        quota.isHidden = false
        drillIn.isHidden = true
        refresh()
        window?.makeFirstResponder(boardView)   // keyboard nav resumes on the board
    }

    /// Ctrl+Tab: open the switcher preview on the first press — NOT a blind cycle; the
    /// operator sees where they're going before anything switches — then step the
    /// highlight on each further press while ⌃ stays held (⇧ reverses, wrapping). The
    /// list is snapshotted at open: NEEDS YOU cards first, then the rest, each tier
    /// most-recently-focused first. A no-op when there's nowhere else to go, so the
    /// chord still means "jump into a task" from the board and stays quiet on a lone
    /// focused card.
    func advanceSwitcher(reverse: Bool) {
        if switcherIsOpen {
            let count = switcherSnapshot.count
            switcherIndex = (switcherIndex + (reverse ? -1 : 1) + count) % count
        } else {
            // Display cards, not the model: the switcher is a second place the board
            // "reads" a state, and it must not offer a frozen `working` either (US-007).
            // Done cards are finished work — they stay reachable from the board but
            // don't belong in a quick-switch rotation.
            let drillable = displayCards().filter { $0.state != .done && ptyByCard[$0.id] != nil }
            let ordered = TaskSwitcherOverlay.ordered(cards: drillable, mru: mruOrder)
            let current = drilledInCardID
            guard ordered.contains(where: { $0.id != current }) else { return }
            switcherSnapshot = ordered
            switcherIndex = TaskSwitcherOverlay.initialHighlight(
                in: ordered, current: current, reverse: reverse)
        }
        taskSwitcher.render(cards: switcherSnapshot, highlight: switcherIndex)
        taskSwitcher.isHidden = false
    }

    /// ⌃ released: switch to the highlighted card WITHOUT bouncing off the board.
    /// Landing back on the current card — or on one that died while the overlay was
    /// up — just closes the preview. The switch hands the target a clean single-reader
    /// slate: detach the live drill-in surface so a switch never strands a second
    /// off-screen reader on one fd or a stale `drilledInCardID`; `drill(into:)` rebuilds
    /// the target's own surface and the pump resumes draining the card we just left.
    func commitSwitcher() {
        let chosen = switcherSnapshot.indices.contains(switcherIndex)
            ? switcherSnapshot[switcherIndex] : nil
        dismissSwitcher()
        guard let chosen,
              let live = cards.first(where: { $0.id == chosen.id }),
              live.id != drilledInCardID else { return }
        teardownFocusForSwitch()
        drill(into: live)
    }

    /// Esc while the overlay is up: back out with no switch.
    func cancelSwitcher() { dismissSwitcher() }

    private func dismissSwitcher() {
        switcherSnapshot = []
        switcherIndex = 0
        taskSwitcher.isHidden = true
    }

    /// Record a focus event (most recent first) — feeds the switcher's MRU ranking.
    private func noteFocus(_ id: UUID) {
        mruOrder.removeAll { $0 == id }
        mruOrder.insert(id, at: 0)
    }

    /// Detach the live drill-in surface without un-hiding the board, so a Ctrl+Tab
    /// switch flows one task straight into the next. Idempotent.
    private func teardownFocusForSwitch() {
        drillIn.detachSurface()
        drilledInCardID = nil
    }

    /// Re-derive the view from the current model — the single render path, so a
    /// live state change just re-runs this (US-003 AC#3 / US-005 live update).
    private func refresh(includeQuota: Bool = true) {
        let shown = displayCards()
        let gauges = QuotaProjection.gauges(from: quotaSources)
        let quotaBlocks = quotaBlocks(for: shown, gauges: gauges)
        let switchMenus = switchMenus(for: shown, gauges: gauges)
        alertIfAttentionRose(to: Attention.count(shown))
        notifyNewlyDone()
        boardView.render(
            cards: shown,
            quotaBlocks: quotaBlocks,
            switchMenus: switchMenus)
        if !backlogPage.isHidden { backlogPage.render(backlogTasks) }
        if !archivePage.isHidden { archivePage.render(archivedTasks) }
        if includeQuota {
            quota.render(
                gauges: gauges, cards: shown,
                claudeProfiles: agentAccountStore.profiles,
                claudeProfileByCard: claudeProfileByCardMap())
        }
        // Keep the drill-in's status pill / waiting banner tracking the live state.
        if let id = drilledInCardID, let card = shown.first(where: { $0.id == id }) {
            drillIn.update(state: card.state)
        }
    }

    /// Per-card quota block derived from harness + account + live gauges.
    private func quotaBlocks(for cards: [BoardCard], gauges: [QuotaGauge]) -> [UUID: CardQuotaBlock] {
        let profiles = agentAccountStore.claudeProfiles
        let byCard = claudeProfileByCardMap()
        var result: [UUID: CardQuotaBlock] = [:]
        for card in cards {
            result[card.id] = CardQuotaAdvisor.block(
                for: card, profileID: byCard[card.id],
                claudeProfiles: profiles, gauges: gauges)
        }
        return result
    }

    /// Context-menu targets for account/harness moves on local and remote cards.
    private func switchMenus(for cards: [BoardCard], gauges: [QuotaGauge]) -> [UUID: CardSwitchMenu] {
        let profiles = agentAccountStore.claudeProfiles
        let byCard = claudeProfileByCardMap()
        var result: [UUID: CardSwitchMenu] = [:]
        for card in cards where canSwitchHarness(card) {
            let host = switchHost(for: card)
            let currentProfile = byCard[card.id]
            let accounts: [CardSwitchMenu.AccountOption]
            if AgentAccountBackend.supportsMultiAccount(card.agent) {
                accounts = agentAccountStore.selectable(for: card.agent, host: host)
                    .filter { $0.id != currentProfile }
                    .map { account in
                        let block = CardQuotaAdvisor.block(
                            for: BoardCard(
                                id: card.id, sessionID: card.sessionID, title: card.title,
                                projectDir: card.projectDir, agent: card.agent,
                                state: card.state),
                            profileID: account.id, claudeProfiles: profiles, gauges: gauges)
                        return CardSwitchMenu.AccountOption(
                            id: account.id, name: account.name, quotaBlock: block)
                    }
            } else {
                accounts = []
            }
            let harnesses = CardAgent.allCases.filter { $0 != card.agent && supportsHarnessSwitch($0) }
            result[card.id] = CardSwitchMenu(accounts: accounts, harnesses: harnesses)
        }
        return result
    }

    private func canSwitchHarness(_ card: BoardCard) -> Bool {
        guard card.state != .done else { return false }
        return isLocalCard(card) || isRemoteCard(card)
    }

    private func isLocalCard(_ card: BoardCard) -> Bool {
        card.host == nil && taskMetaByCard[card.id]?.remote == nil
    }

    private func isRemoteCard(_ card: BoardCard) -> Bool {
        taskMetaByCard[card.id]?.remote != nil || card.host != nil
    }

    /// The host key for account selection — nil for local, the remote hostname otherwise.
    private func switchHost(for card: BoardCard) -> String? {
        taskMetaByCard[card.id]?.remote?.host ?? Self.relayHost(of: card) ?? card.host
    }

    private func supportsHarnessSwitch(_ agent: CardAgent) -> Bool {
        switch agent {
        case .claude, .codex, .cursor, .antigravity: return true
        case .gemini: return false
        }
    }

    /// Move a task to another account on the same harness, with a context handoff.
    func switchAccount(on card: BoardCard, to accountID: UUID) {
        guard canSwitchHarness(card),
              let account = agentAccountStore.account(id: accountID),
              account.agent == card.agent else { return }
        relaunch(card: card, agent: card.agent, profileID: account.id, handoffFrom: card)
    }

    /// Continue a task on a different harness, with a context handoff.
    func switchHarness(on card: BoardCard, to agent: CardAgent) {
        guard canSwitchHarness(card), supportsHarnessSwitch(agent) else { return }
        let host = switchHost(for: card)
        let profileID = AgentAccountBackend.supportsMultiAccount(agent)
            ? agentAccountStore.selectable(for: agent, host: host).first?.id
            : nil
        relaunch(card: card, agent: agent, profileID: profileID, handoffFrom: card)
    }

    /// Tear down the live session and relaunch under a new harness/account on the
    /// same card id, seeding the new agent with a handoff prompt.
    private func relaunch(
        card: BoardCard, agent: CardAgent, profileID: UUID?, handoffFrom prior: BoardCard
    ) {
        if isRemoteCard(card) {
            relaunchRemote(card: card, agent: agent, profileID: profileID, handoffFrom: prior)
            return
        }
        if drilledInCardID == card.id { returnToBoard() }
        let handoff = buildHandoffContext(from: prior)
        terminateOwnedSession(for: card.id)
        guard let idx = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[idx] = cards[idx].with(agent: agent).with(state: .idle)
        let cwd = taskMetaByCard[card.id]?.sessionRef?.lastCwd ?? card.projectDir
        taskMetaByCard[card.id, default: CardTaskMeta()].claudeProfileID = profileID
        taskMetaByCard[card.id]?.sessionRef = TaskSessionRef(claudeSessionID: nil, lastCwd: cwd)
        guard let session = openRelaunchedSession(
            card: cards[idx], agent: agent, profileID: profileID, handoff: handoff
        ) else { return }
        ptyByCard[card.id] = session.pty
        workLog?.noteEvent(
            "relaunched on \(agent.displayName)\(profileLabel(profileID)) with context handoff",
            card: cards[idx])
        refresh()
        persistTasks()
    }

    /// Remote variant: detach the local ssh client, re-attach to the same tmux
    /// session, interrupt whatever is running, and start the new harness there.
    private func relaunchRemote(
        card: BoardCard, agent: CardAgent, profileID: UUID?, handoffFrom prior: BoardCard
    ) {
        guard let spec = remoteSpec(for: card) ?? taskMetaByCard[card.id]?.remote else { return }
        if drilledInCardID == card.id { returnToBoard() }
        let handoff = buildHandoffContext(from: prior)
        terminateOwnedSession(for: card.id)
        guard let idx = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[idx] = cards[idx].with(agent: agent).with(state: .idle)
        let cwd = remoteWorkingDir(for: card) ?? spec.remoteDir ?? card.projectDir
        taskMetaByCard[card.id, default: CardTaskMeta()].claudeProfileID = profileID
        taskMetaByCard[card.id]?.sessionRef = TaskSessionRef(claudeSessionID: nil, lastCwd: cwd)
        guard let session = openRelaunchedRemoteSession(
            card: cards[idx], spec: spec, agent: agent, profileID: profileID, handoff: handoff
        ) else { return }
        ptyByCard[card.id] = session.pty
        workLog?.noteEvent(
            "relaunched on \(agent.displayName)\(profileLabel(profileID)) with context handoff",
            card: cards[idx])
        refresh()
        persistTasks()
    }

    private func profileLabel(_ profileID: UUID?) -> String {
        guard let profileID, let account = agentAccountStore.account(id: profileID) else { return "" }
        return " (\(account.name))"
    }

    private func terminateOwnedSession(for cardID: UUID) {
        let pty = ptyByCard.removeValue(forKey: cardID)
        pty?.terminate()
        if let pty, let dead = registry.all.first(where: { $0.pty === pty }) {
            registry.remove(id: dead.id)
        }
    }

    private func buildHandoffContext(from card: BoardCard) -> String {
        let remote = isRemoteCard(card)
        let profileID = taskMetaByCard[card.id]?.claudeProfileID
        let account = agentAccountStore.account(id: profileID)
        let session = ptyByCard[card.id].flatMap { pty in
            registry.all.first { $0.pty === pty }
        }
        let cwd = remote
            ? (remoteWorkingDir(for: card) ?? card.projectDir)
            : (session?.reportedCwd
                ?? taskMetaByCard[card.id]?.sessionRef?.lastCwd
                ?? card.projectDir)
        let claudeRoot = account.flatMap { $0.agent == .claude ? $0.resolvedConfigRoot : nil }
            ?? ClaudeLaunchEnv.defaultConfigDir.path
        let request = AgentTranscriptLocator.Request(
            agent: card.agent,
            projectDir: cwd,
            claudeSessionID: session?.claudeSessionID
                ?? taskMetaByCard[card.id]?.sessionRef?.claudeSessionID,
            claudeConfigRoot: claudeRoot,
            codexHome: account.flatMap { $0.agent == .codex ? $0.resolvedConfigRoot : nil },
            cursorConfigRoot: account.flatMap { $0.agent == .cursor ? $0.resolvedConfigRoot : nil }
        )
        let transcriptPath = remote
            ? AgentTranscriptLocator.expectedPath(request)
            : AgentTranscriptLocator.locate(request)
        let logURL = workLog?.fileURL(for: card.id)
        let logTail = logURL.flatMap { url -> String? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return HarnessHandoff.tail(ofWorkLog: text)
        }
        return HarnessHandoff.prompt(
            title: card.title, projectDir: cwd,
            priorAgent: card.agent, priorAccountName: account?.name,
            priorTranscriptPath: transcriptPath,
            workLogTail: logTail)
    }

    /// The far-side working directory learned from hooks or the card's spec.
    private func remoteWorkingDir(for card: BoardCard) -> String? {
        if let cwd = taskMetaByCard[card.id]?.sessionRef?.lastCwd, cwd.hasPrefix("/") {
            return cwd
        }
        if let pty = ptyByCard[card.id],
           let session = registry.all.first(where: { $0.pty === pty }),
           let cwd = session.reportedCwd, cwd.hasPrefix("/") {
            return cwd
        }
        return taskMetaByCard[card.id]?.remote?.remoteDir
    }

    private func openRelaunchedSession(
        card: BoardCard, agent: CardAgent, profileID: UUID?, handoff: String
    ) -> Session? {
        let dir = taskMetaByCard[card.id]?.sessionRef?.lastCwd ?? card.projectDir
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        let seed = BoardSeed.liveTerminal(
            projectDir: dir, sessionID: card.sessionID, title: card.title,
            cardID: card.id.uuidString, agent: agent,
            accountEnv: accountEnvExports(for: profileID, agent: agent)
        )
        guard let session = launch(seed) else { return nil }
        startAgent(in: session, agent: agent, handoff: handoff, via: .localShim)
        return session
    }

    private func openRelaunchedRemoteSession(
        card: BoardCard, spec: RemoteTmuxSpec, agent: CardAgent,
        profileID: UUID?, handoff: String
    ) -> Session? {
        let account = agentAccount(for: profileID)
        let tmuxEnv = account.map { AgentAccountBackend.remoteTmuxEnvironment(for: $0) } ?? []
        let conversation = agent == .claude ? UUID() : nil
        guard let seed = try? BoardSeed.remoteTmux(
            spec: spec, sessionID: card.sessionID, title: card.title,
            cardID: card.id.uuidString, agent: agent,
            tmuxEnvironment: tmuxEnv,
            agentCommand: conversation.map(RemoteTmuxCommand.claudeStart(sessionID:))
        ), let session = launch(seed) else { return nil }
        adoptRestoredRemote(spec, on: session)
        if let conversation {
            session.recordClaudeSession(conversation)
        }
        scheduleRemoteAgentStart(
            in: session, agent: agent, profileID: profileID, handoff: handoff)
        return session
    }

    private func startAgent(
        in session: Session, agent: CardAgent, handoff: String,
        via launcher: HarnessLauncher
    ) {
        switch agent {
        case .claude:
            session.recordClaudeSession(session.id)
            _ = session.pty.send(Array(Self.startClaudeCommand(sessionID: session.id, via: launcher).utf8))
        case .codex:
            if launcher == .localShim { HookInstaller.installCodexShim() }
            _ = session.pty.send(Array(Self.startCodexCommand(via: launcher).utf8))
        case .cursor:
            if launcher == .localShim { HookInstaller.installCursorHooks() }
            _ = session.pty.send(Array(Self.startCursorCommand(via: launcher).utf8))
        case .antigravity:
            if launcher == .localShim { HookInstaller.installAntigravityHooks() }
            _ = session.pty.send(Array(Self.startAntigravityCommand(via: launcher).utf8))
        case .gemini:
            break
        }
        scheduleHandoff(handoff, to: session)
    }

    /// After re-attaching over ssh, interrupt the running process and start the
    /// new harness on the far side. The keystrokes go through `sendWhenReady`, so
    /// they reach the PANE once the control-mode attach has bound it — never the
    /// handshake; the handoff follows the start command.
    private func scheduleRemoteAgentStart(
        in session: Session, agent: CardAgent, profileID: UUID?, handoff: String
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak session] in
            guard let session else { return }
            session.pty.sendWhenReady([0x03])   // Ctrl-C — stop whatever is running
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak session] in
                guard let session else { return }
                let prefix = Self.remoteAccountPrefix(for: profileID, agent: agent,
                                                      in: self.agentAccountStore)
                switch agent {
                case .claude:
                    let id = session.claudeSessionID ?? UUID()
                    session.recordClaudeSession(id)
                    let cmd = prefix + Self.startClaudeCommand(sessionID: id, via: .remotePath)
                    session.pty.sendWhenReady(Array(cmd.utf8))
                case .codex:
                    let cmd = prefix + Self.startCodexCommand(via: .remotePath)
                    session.pty.sendWhenReady(Array(cmd.utf8))
                case .cursor:
                    let cmd = prefix + Self.startCursorCommand(via: .remotePath)
                    session.pty.sendWhenReady(Array(cmd.utf8))
                case .antigravity:
                    let cmd = prefix + Self.startAntigravityCommand(via: .remotePath)
                    session.pty.sendWhenReady(Array(cmd.utf8))
                case .gemini:
                    break
                }
                self.scheduleHandoff(handoff, to: session)
            }
        }
    }

    /// Shell exports for a remote account switch, typed before the agent start.
    private static func remoteAccountPrefix(
        for profileID: UUID?, agent: CardAgent, in store: AgentAccountStore
    ) -> String {
        guard let profileID, let account = store.account(id: profileID),
              account.agent == agent else { return "" }
        let pairs = AgentAccountBackend.remoteTmuxEnvironment(for: account)
        guard !pairs.isEmpty else { return "" }
        return pairs.map { name, value in
            "export \(name)=\(shellQuotedRemote(value)); "
        }.joined()
    }

    private static func shellQuotedRemote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Give the agent a moment to start, then paste the handoff as the first prompt.
    private func scheduleHandoff(_ text: String, to session: Session) {
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak session] in
            guard let session else { return }
            _ = session.pty.send(Array((payload + "\n").utf8))
        }
    }

    // MARK: - Link health (US-007)

    /// The bound the story names as X: how long a card may keep showing a stale
    /// reading after its host's link is declared dead. One sessions-poll backstop
    /// cycle, which is what actually carries the change to the screen — a DIFFERENT
    /// quantity from how long DETECTION took (an ssh child exit is immediate; a
    /// silent partition takes up to the keepalive budget on the relay's argv).
    ///
    /// Nothing reads it at runtime — the board has no timer of its own here, it rides
    /// the sessions poll. It is the written-down ceiling that poll must stay under, and
    /// the test that pins `SessionsPoller.defaultInterval` beneath it is its only
    /// reader, which is precisely the point: raise the cadence past 5s and US-007's
    /// promise breaks silently.
    // periphery:ignore - a stated bound, asserted in tests (scan runs with exclude_tests)
    static let unreachableVisibleWithin: TimeInterval = 5

    /// What the board shows: the model in `cards`, with every card on a host whose
    /// relay reports a dead link overlaid as `.unreachable`.
    ///
    /// Derived per render, never stored. That is the whole recovery story — the last
    /// observed state stays untouched in `cards`, so a link that comes back restores
    /// it on the very next render with no bookkeeping and no "what was it before"
    /// map. Cards on hosts nobody relays for (every local card) pass through: `nil`
    /// health is silence, not a verdict, and a reachable host with no forwarder
    /// installed stays an install-state message on the host chip.
    ///
    /// A DONE card is exempt: completion is settled, nothing on the far side can
    /// change it, so a dead link (e.g. the host lives on a tailnet you are not on
    /// right now) must not drag finished work back into PARKED.
    func displayCards() -> [BoardCard] {
        guard let sessionsPoller else { return cards }
        return cards.map { card in
            guard card.state != .done,
                  let host = card.host ?? Self.relayHost(of: card),
                  sessionsPoller.relayHealth(for: host) == .unreachable
            else { return card }
            return card.with(state: .unreachable)
        }
    }

    /// The host a card we OPENED is bound to, for the window before any hook line has
    /// come back to stamp `host` on it — which is exactly the window a link that never
    /// came up lives in. Read back out of the card's `remote/<host>/<session>` id
    /// through the same parser that wrote it, so the two spellings cannot drift.
    private static func relayHost(of card: BoardCard) -> String? {
        RemoteSessionKey.parse(sessionID: card.sessionID)?.host
    }

    /// Every host currently declared dead — part of the render signature, so a link
    /// dying is a real change even when not one event line moved (US-007 AC-1). The
    /// backstop poll pushes cards unconditionally, so this is what turns that tick
    /// into a repaint.
    private func unreachableHosts(among candidates: [BoardCard]) -> Set<String> {
        guard let sessionsPoller else { return [] }
        let hosts = candidates.filter { $0.state != .done }
            .compactMap { $0.host ?? Self.relayHost(of: $0) }
        return Set(hosts.filter { sessionsPoller.relayHealth(for: $0) == .unreachable })
    }

    /// Fire a "task done" OS notification on the rising edge into the manual DONE
    /// state. Edge-triggered off `lastCardStates` so it fires once per completion,
    /// not on every refresh while the card remains there.
    private func notifyNewlyDone() {
        for card in cards {
            let previous = lastCardStates[card.id]
            lastCardStates[card.id] = card.state
            // Item 7 (18.08): the attention clock ages the "needs you" signal.
            AttentionClock.shared.note(card)
            // Item 6 (18.08): every edge any card takes lands in its work journal —
            // this sweep already sees them all, so it is the one feed the log needs.
            if let previous {
                workLog?.noteState(from: previous, of: card)
            } else {
                workLog?.noteAppeared(card)
            }
            guard card.state == .done, previous != nil, previous != .done else { continue }
            guard !NSApp.isActive else { continue }
            SystemNotifier.notifyDone(taskName: card.title ?? BoardTheme.shortPath(card.projectDir))
        }
        // Drop states for cards that no longer exist so the map can't grow unbounded.
        let live = Set(cards.map(\.id))
        lastCardStates = lastCardStates.filter { live.contains($0.key) }
        AttentionClock.shared.retain(live)
    }

    // MARK: - Rule 1: NEEDS YOU standup (docs/OPERATING-RULES.md)

    private static let standupStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func registerNeedsYouStandupObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentNeedsYouStandupIfNeeded() }
        }
    }

    /// Surfaces stale NEEDS YOU cards until the operator responds, defers, or snoozes.
    func presentNeedsYouStandupIfNeeded() {
        guard ProcessInfo.processInfo.environment["SICH_E2E"] == nil else { return }
        guard !needsYouStandupOpen else { return }
        guard drilledInCardID == nil, backlogPage.isHidden,
              archivePage.isHidden, createPalette == nil else { return }
        let stale = NeedsYouStandup.staleCards(
            among: cards,
            waitingSince: { AttentionClock.shared.waitingSince($0) },
            deferredUntil: { taskMetaByCard[$0]?.needsYouDeferredUntil }
        )
        guard let card = stale.first,
              let since = AttentionClock.shared.waitingSince(card.id) else { return }

        needsYouStandupOpen = true
        defer { needsYouStandupOpen = false }

        let choice = NeedsYouStandupPrompt.run(for: card, waitingSince: since)
        switch choice {
        case .respondNow:
            drill(into: card)
        case .deferUntilTomorrow:
            deferNeedsYouToTomorrow(cardID: card.id)
            DispatchQueue.main.async { [weak self] in self?.presentNeedsYouStandupIfNeeded() }
        case .markDone:
            move(cardID: card.id, to: .done)
            DispatchQueue.main.async { [weak self] in self?.presentNeedsYouStandupIfNeeded() }
        case .cancelled:
            break
        }
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
        quota.render(
            gauges: gauges, cards: cards,
            claudeProfiles: agentAccountStore.profiles,
            claudeProfileByCard: claudeProfileByCardMap())
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
    /// session's live state (idle → running → waiting) and slides between those
    /// columns as the model works — instead of one physical terminal showing up as a
    /// second, drifting card. A detected session completion is deliberately ignored:
    /// only a manual move changes task status to DONE. Identity, title, and PTY are
    /// untouched, so a drilled-in terminal keeps working; only the column changes.
    /// Observed sessions we never spawned are merged in as status-only cards. Re-renders
    /// only on a real change, and never yanks the board out from under an active drill-in.
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
        // ptys carries that card's UUID (SICH_CARD_ID → hook line), so it binds to
        // its owned card even when several task cards share the repo dir and the dir
        // join is suppressed. This is what kills the "unclickable duplicate card".
        // A card with NO pty (a durable task resurrected from the task book, its shell
        // long gone) passes through untouched — the 3s poll must not drop it.
        let adopted = cards.map { card in
            guard ptyByCard[card.id] != nil else { return card }
            let byDir = uniqueDirs.contains(Self.normDir(card.projectDir))
            let bound = observed.filter { $0.boundCardID == card.id.uuidString }
            if let freshest = bound.max(by: { Self.staler($0, $1) }) {
                learnRemoteFacts(from: freshest, for: card)
                return smoothLiveState(card: card, observed: freshest.state)
            }
            if let state = liveState(for: card, joinByDir: byDir, in: observed) {
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
            + unreachableHosts(among: merged).sorted().map { "link-dead|\($0)" }
        guard signature != lastSessionsSignature else { return }
        lastSessionsSignature = signature
        cards = merged   // ptyByCard keeps its owned entries → drill-in still works
        // US-005: re-render even while drilled in so the board (and the Dock badge)
        // reflect reality on return, not a frozen snapshot. The focused terminal lives
        // in the separate `drillIn` panel; while drilled, `boardView` and `quota` are
        // hidden, so `refresh()` rebuilds hidden card
        // views without touching the live terminal's superview. ponytail: full refresh,
        // no teardown — the old `focusedCardID == nil` guard is gone.
        refresh()
        persistTasks()
    }

    /// Learn from a REMOTE card's bound hook line the two facts only the far side knows:
    /// which conversation it is driving, and which directory it is driving it in.
    ///
    /// A local card is told both at launch — we pin the conversation id and we chose the
    /// cwd. A remote card is told neither: the operator runs `claude` themselves inside
    /// tmux, in whatever directory they `cd` to. Until these are captured, a session the
    /// far side LOSES (a reboot, an OOM sweep, a killed tmux server) comes back as a bare
    /// login shell at `$HOME` with the conversation stranded — which is precisely what a
    /// dropped link looked like. Recorded on the live session, so the existing
    /// ``sessionRef(for:)`` persists them with no second storage path.
    private func learnRemoteFacts(from observed: BoardCard, for card: BoardCard) {
        guard let pty = ptyByCard[card.id],
              let session = registry.all.first(where: { $0.pty === pty }),
              session.remoteSpec != nil else { return }
        if let conversation = UUID(uuidString: observed.sessionID) {
            session.recordClaudeSession(conversation)
        }
        // The hook's `cwd`, which for a remote line is a far-side absolute path. The
        // relative label an unbound entry falls back to (its own session id) is not one.
        if observed.projectDir.hasPrefix("/") {
            session.reportCwd(observed.projectDir)
        }
    }

    // A model "thinking" between tool calls emits no hook events for many seconds,
    // so the observed state dips to idle mid-turn; 2s was shorter than routine
    // thinking gaps and the card stuttered working→idle→working. Only a SUSTAINED
    // idle should demote the card — attention/blocked and manual moves stay immediate.
    private static let idleHoldInterval: TimeInterval = 15.0

    /// Hook snapshots can briefly report `idle` between active tool events, and a
    /// long-running tool call (a 2-minute build emits nothing between PreToolUse and
    /// its result) decays to `unknown` via the stale sweep. Holding these two
    /// working→at-rest live transitions prevents column jitter while keeping
    /// attention, blocked, and manual moves immediate. Detector output never moves a
    /// task into DONE; completion is an operator decision.
    private func smoothLiveState(card: BoardCard, observed state: CardState) -> BoardCard {
        let next = detectorSafeState(card: card, observed: state)
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

    /// Reconcile detector output without surrendering manual task placement. DONE is
    /// a manual-only column in both directions: a manually completed task stays there
    /// until the operator moves it, and an observed session completion cannot put an
    /// active task there. BLOCKED and PARKED are manual in the same sense — they say
    /// something the agent cannot know (you are waiting on a PR, you shelved this) —
    /// so a live session's next turn end must not pull them back to NEEDS YOU. Other
    /// live states continue to move non-held cards.
    private func detectorSafeState(card: BoardCard, observed state: CardState) -> CardState {
        if card.state == .done || state == .done { return card.state }
        if operatorHeldCardIDs.contains(card.id) { return card.state }
        return state
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
    /// Both joins are scoped to the card's MACHINE first (`sich_host`, `nil` = this
    /// laptop): a session id and a cwd are only unique within one host, so a build box
    /// checking out the same repo path — or handing out the same session id — must not
    /// move a local card (US-004 AC-3). Cross-machine binding happens only through the
    /// explicit `SICH_CARD_ID` path above, which is host-independent by construction.
    private func liveState(for card: BoardCard, joinByDir: Bool, in observed: [BoardCard]) -> CardState? {
        let dir = Self.normDir(card.projectDir)
        let id = card.sessionID
        return observed
            .filter { $0.host == card.host }
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
        case .idle, .parked:             return 1
        // Never observed on a store entry (the board derives it at render time), and
        // ranked with `unknown` if one ever reached here: it says nothing about which
        // session is live.
        case .unknown, .unreachable:     return 0
        }
    }
}

/// The per-card slice of a ``TaskRecord`` that ``BoardCard`` doesn't carry itself:
/// the backlog description, the chosen launch mode, and the task's original
/// creation time (which predates the card when the task began in the backlog).
struct CardTaskMeta {
    var details: String = ""
    var createdAt = Date()
    /// Resume hints carried over from the loaded task book for a card whose shell
    /// didn't survive. Without this, the first save after adoption re-derives the
    /// ref from live sessions (there is none) and wipes the pinned conversation id.
    var sessionRef: TaskSessionRef?
    /// The remote tmux spec for a remote card — the constructor's INPUT, kept at
    /// the card level so the task book can persist it and a session-less remote
    /// card can rebuild its attach on drill-in (the far side is still running).
    var remote: RemoteTmuxSpec?
    /// Which Claude Code account (`CLAUDE_CONFIG_DIR`) this card's sessions use.
    var claudeProfileID: UUID?
    /// Rule 1 snooze: do not treat NEEDS YOU as stale until this instant.
    var needsYouDeferredUntil: Date?
}
