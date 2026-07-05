import AppKit
import GhostlingCore

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
    let drillIn = DrillInPanel()
    // The quota panel folded in as a right-side region — one assembled window
    // shows the board AND the four never-netted gauges (no separate binary).
    let quota = QuotaPanel()
    // The live data bridge — fully native after the Phase-03 cutover (DD-001/DD-002):
    // quota reads in-process from disk (no `GET /quota`, no sidecar) and sessions
    // arrive by tailing the observe-only event file (no `/sessions`, no port).
    // Started only on the real launch path (not in tests).
    private var quotaPoller: NativeQuotaPoller?
    private var sessionsPoller: SessionsPoller?
    // The always-on pty drain (the fix for "work stops when I leave the task"): one
    // main-run-loop timer that reads EVERY owned session's pty each tick — not just
    // the drilled-in one — so an off-screen agent's child never blocks on a full
    // kernel buffer. Its own surface drains the drilled-in card, so the pump skips it.
    private var sessionPumpTimer: Timer?
    private var drilledInCardID: UUID?
    // Pump ticks since launch — the reconcile pass piggybacks on the pump timer at
    // a ~1s cadence (one waitpid(WNOHANG) per live session; no extra timer).
    private var pumpTick = 0
    // Cards whose child died WHILE drilled in: the surface shows the end banner
    // first; the card is swept off the board when the operator returns to it.
    private var deadCardIDs: Set<UUID> = []
    // Attention count at the previous render — alerts fire only on a RISE.
    private var lastAttentionCount = 0
    // Last applied live-session snapshot signature — re-render only on a real change
    // so the 3s poll doesn't tear down and rebuild identical card views (flicker).
    private var lastSessionsSignature: [String] = []

    private var selection = BoardSelection()
    private(set) var cards: [BoardCard] = []
    private var ptyByCard: [UUID: PTYSession] = [:]
    // Repo root for the live-terminal cwd and the hook installer (resolved once).
    private let repoRoot = RepoLocator.repoRoot()
    // Monotonic suffix so each "+ new session" card gets a unique sessionID.
    private var sessionCounter = 0

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
        // US-003: reload + re-open the pre-quit session tree before the fresh seed lands.
        restorePreviousSessions()
        seedSessions()
        makeWindow()
        wireInteractions()
        refresh()
        startSessionPump()
        startQuotaBridge()
        // Auto-wire the board's hook forwarder so real interactive sessions in this
        // repo appear on the board — the app installs it (the agent can't). Launch
        // path only, never the headless test build.
        if let repoRoot { HookInstaller.install(repoRoot: repoRoot) }
        // US-004: install Ghostty shell-integration the same way (idempotent; non-zsh
        // and write failures degrade gracefully) so the shell reports cwd semantically.
        installShellIntegration(installRoot: Self.shellIntegrationRoot(), rc: Self.defaultZshrc())
        maybeRunE2E()
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
        let sessionsPoller = SessionsPoller { [weak self] cards in self?.applySessions(cards) }
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
        for (id, pty) in ptyByCard where id != drilledInCardID && pty.masterFD >= 0 {
            pty.setNonBlocking()          // idempotent
            drain: while true {
                switch pty.pumpAvailable() {
                case .data: sawData = true; continue drain
                case .idle, .eof: break drain
                }
            }
        }
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

    /// Keep the board honest about death: poll every owned child (`waitpid` WNOHANG
    /// via the registry) and reflect any that exited or crashed. A dead card off
    /// screen is removed outright (its shell is gone — a stale card is a lie); the
    /// drilled-in card first shows the end banner on its surface and is swept when
    /// the operator returns to the board. This is the BoardShell counterpart of the
    /// AppShell reconcile the shipped app never ran.
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
        try? store.save(windows: registry.snapshotWindows())
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
        let card = BoardCard(
            sessionID: pane.snapshot.sessionID.uuidString, projectDir: pane.cwd,
            agent: Self.cardAgent(for: pane.snapshot.agentType),
            flow: Self.cardFlow(for: pane.snapshot.flowTag), state: .idle
        )
        cards.append(card)
        ptyByCard[card.id] = session.pty
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
    /// bypass the real Esc/click → return chain. Returns the root content view.
    @discardableResult
    func buildContentForTesting() -> NSView {
        seedSessions()
        let root = makeContentView(in: NSSize(width: 1280, height: 720))
        wireInteractions()
        root.layoutSubtreeIfNeeded()
        return root
    }

    // MARK: - Seeding

    private func seedSessions() {
        for seed in seeds {
            guard let session = launch(seed) else { continue }
            let card = BoardCard(
                id: seed.cardID.flatMap(UUID.init(uuidString:)) ?? UUID(),
                sessionID: seed.sessionID, title: seed.title, projectDir: seed.projectDir,
                agent: seed.agent, flow: seed.flow, state: seed.state
            )
            cards.append(card)
            ptyByCard[card.id] = session.pty
        }
    }

    private func launch(_ seed: BoardSeed) -> Session? {
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

    private func makeWindow() {
        let window = NSWindow(
            // 1400×860: wide enough that all 5 columns + the quota panel fit on
            // launch, yet still fits a 1440-wide laptop screen after .center().
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Ghostling — mission control"
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
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = BoardTheme.canvas.cgColor
        // The whole UI is a hand-painted dark theme on near-black surfaces. Tell
        // AppKit it IS dark so any standard control chrome (text-field focus rings,
        // selection) is drawn light-on-dark rather than light/aqua.
        root.appearance = NSAppearance(named: .darkAqua)
        layout(attention, in: root, header: true)
        layoutQuota(in: root)
        layout(boardView, in: root, header: false)
        drillIn.isHidden = true
        layoutDrillIn(in: root)
        return root
    }

    /// The quota panel pinned to the trailing edge as a fixed-width column, from
    /// just under the header to the bottom — the board fills the remaining width.
    private func layoutQuota(in root: NSView) {
        quota.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(quota)
        NSLayoutConstraint.activate([
            quota.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            quota.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            quota.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            quota.widthAnchor.constraint(equalToConstant: 340),
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
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ]
    }

    private func boardConstraints(_ v: NSView, in root: NSView) -> [NSLayoutConstraint] {
        [
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            // Board fills the width left of the quota column (not the full root).
            v.trailingAnchor.constraint(equalTo: quota.leadingAnchor, constant: -12),
            v.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
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
        attention.onActivate = { [weak self] in self?.activateAttention() }
        drillIn.onClose = { [weak self] in self?.returnToBoard() }
    }

    /// The "+ new session" affordance: ask what the task IS (a human title) and
    /// where it runs, then create the card. A card is a *task* the operator is
    /// working on, not an anonymous `terminal-N` — naming it at birth is what makes
    /// the board legible. Cancelling the prompt creates nothing.
    func promptAndCreateSession() {
        guard let task = promptForNewTask() else { return }
        createSession(title: task.title.isEmpty ? nil : task.title, projectDir: task.dir,
                      startClaude: task.startClaude)
        rememberProjectDir(task.dir)
    }

    /// A small native modal asking for the task title + project folder. The folder is
    /// a list of recent folders as clickable rows (designer Approach A), with a
    /// "Choose…" row opening the native `NSOpenPanel` — no path-typing. Returns the
    /// trimmed values, or `nil` if cancelled.
    /// ponytail: NSAlert + a custom accessory keeps the stdlib modal shell (Esc to
    /// cancel, ↵ to create) while swapping just the folder control the operator disliked.
    private func promptForNewTask() -> (title: String, dir: String, startClaude: Bool)? {
        let recents = recentProjectDirs()
        let alert = NSAlert()
        alert.messageText = "New task"
        alert.informativeText = "Name the work, then pick where it runs."
        alert.addButton(withTitle: "Create task")
        alert.addButton(withTitle: "Cancel")
        let titleField = NSTextField()
        titleField.placeholderString = "e.g. Fix the login redirect"
        let picker = FolderPickerView(recentDirs: recents)
        picker.onBrowse = { [weak alert] in Self.chooseFolder(relativeTo: alert?.window) }
        // Interactive `claude` typed into the login shell — the same keystrokes the
        // operator would type; never `claude -p` (pool firewall untouched).
        let startClaude = NSButton(checkboxWithTitle: "Start claude in it", target: nil, action: nil)
        startClaude.state = .on
        alert.accessoryView = makeTaskAccessory(titleField: titleField, picker: picker,
                                                startClaude: startClaude)
        alert.window.initialFirstResponder = titleField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, picker.selectedDir.isEmpty ? (recents.first ?? "") : picker.selectedDir,
                startClaude.state == .on)
    }

    /// Stack the captioned title field over the folder picker, sized to fit so NSAlert
    /// lays it out cleanly.
    private func makeTaskAccessory(
        titleField: NSTextField, picker: FolderPickerView, startClaude: NSButton
    ) -> NSView {
        titleField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        picker.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let stack = NSStackView(views: [
            accessoryCaption("Task"), titleField,
            accessoryCaption("Project folder"), picker,
            startClaude,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.setCustomSpacing(11, after: titleField)
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return stack
    }

    /// The native macOS folder chooser, run as a nested modal over the alert.
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

    private func accessoryCaption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = BoardTheme.monoSmall
        label.textColor = BoardTheme.textMuted
        return label
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
    func createSession(title: String? = nil, projectDir: String? = nil, startClaude: Bool = false) {
        sessionCounter += 1
        let chosen = (projectDir?.isEmpty == false) ? projectDir : nil
        let dir = chosen.map { ($0 as NSString).expandingTildeInPath }
            ?? repoRoot?.path ?? FileManager.default.currentDirectoryPath
        // The card id is minted BEFORE launch so it can ride the pty environment
        // (GHOSTLING_CARD_ID) — the identity binding that folds the hook-observed
        // claude session back into this card even when the repo dir is shared.
        let cardID = UUID()
        let seed = BoardSeed.liveTerminal(
            projectDir: dir, sessionID: sessionSlug(title), title: title,
            cardID: cardID.uuidString
        )
        guard let session = launch(seed) else { return }
        let card = BoardCard(
            id: cardID,
            sessionID: seed.sessionID, title: seed.title, projectDir: seed.projectDir,
            agent: seed.agent, flow: seed.flow, state: seed.state
        )
        cards.append(card)
        ptyByCard[card.id] = session.pty
        if startClaude {
            // Type `claude⏎` into the fresh login shell for the operator — the tty
            // input buffer holds it until the shell finishes initialising. Interactive
            // pool only; the firewall against `claude -p` is untouched.
            _ = session.pty.send(Array("claude\n".utf8))
        }
        refresh()
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
        cards[idx] = cards[idx].with(state: column.state)
        refresh()
    }

    /// US-002: drill into a card → full-window terminal takeover (Altitude-1).
    /// The board surface and attention header are hidden so the embedded terminal
    /// is the only thing on screen.
    func drill(into card: BoardCard) {
        guard let pty = ptyByCard[card.id] else { return }
        selection.focus(card.id)
        drilledInCardID = card.id   // its surface owns the fd now; the pump skips it
        boardView.isHidden = true
        attention.isHidden = true
        quota.isHidden = true
        drillIn.isHidden = false
        drillIn.focus(card: card, pty: pty)
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
        quota.isHidden = false
        drillIn.isHidden = true
        refresh()
        window?.makeFirstResponder(boardView)   // keyboard nav resumes on the board
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
        boardView.render(cards: selection.visibleCards(from: cards))
        quota.render(gauges: QuotaProjection.gauges(from: quotaSources))
    }

    /// OS-level nudge when a session newly starts waiting on the operator while
    /// they are in another app: dock badge + bounce + a soft sound. In-app the
    /// header indicator already covers it, so we stay quiet when active.
    /// ponytail: dock badge/bounce, not UNUserNotificationCenter — banner
    /// notifications require a bundled .app, which `swift run` binaries lack.
    private func alertIfAttentionRose(to count: Int) {
        defer { lastAttentionCount = count }
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : ""
        guard count > lastAttentionCount, !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        NSSound(named: "Ping")?.play()
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
        let ownedIDs = Set(owned.map(\.sessionID))
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
                return card.with(state: freshest.state)
            }
            return liveState(forDir: card.projectDir, id: card.sessionID, joinByDir: byDir, in: observed)
                .map(card.with(state:)) ?? card
        }
        // Sessions we never spawned, collapsed to ONE card per project dir: a project
        // that has had several hook session_ids (a fresh run plus finished ones) is the
        // SAME task and shows in the column of its most-live run. Excludes exact owned
        // ids, bound sessions, and ANY session in a dir some owned card occupies —
        // in an ambiguously-owned dir we can't attribute the session to a task, and
        // surfacing it as its own card reads as an unclickable duplicate of the task
        // card (operator-reported). ponytail: this hides a genuinely-other-terminal
        // agent working in a dir you also have task cards in; give observed cards a
        // distinct "observed" look instead of suppressing, if that visibility matters.
        let ownedDirs = Set(dirCount.keys)
        let ownedCardIDs = Set(owned.map(\.id.uuidString))
        let extra = Self.collapseByDir(observed.filter {
            !ownedIDs.contains($0.sessionID)
                && !ownedDirs.contains(Self.normDir($0.projectDir))
                && !($0.boundCardID.map(ownedCardIDs.contains) ?? false)
        })
        let merged = adopted + extra
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

    /// Collapse cards to ONE per project dir, keeping the freshest-then-most-live card
    /// (the same `staler` freshness order used for owned cards, applied
    /// observed-to-observed). Stable: each dir keeps its first-seen slot in the result.
    private static func collapseByDir(_ cards: [BoardCard]) -> [BoardCard] {
        var best: [String: BoardCard] = [:]
        var order: [String] = []
        for card in cards {
            let key = normDir(card.projectDir)
            if best[key] == nil { order.append(key) }
            if let cur = best[key], !staler(cur, card) { continue }  // keep cur unless card is fresher
            best[key] = card
        }
        return order.compactMap { best[$0] }
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
