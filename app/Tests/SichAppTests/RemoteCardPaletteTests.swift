import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// US-009 — picking WHERE a card runs at creation time. Every interaction below is a
/// REAL dispatched `NSEvent` (a `leftMouseDown` hit-tested through the mounted window,
/// or a `keyDown` routed by the window to the focused field editor); no test calls a
/// row handler or a stage method directly — the false pass this repo has shipped three
/// times. Nothing dials a host: the reserved `.invalid` TLD plus an injected launch
/// override mean the "ssh" is a `/bin/cat`, and every recents list is local state.

// MARK: - harness

/// A scratch defaults suite, so a test never touches the operator's real MRU list.
private func scratchDefaults() -> (UserDefaults, String) {
    let suite = "sich.tests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

@MainActor
private struct Board {
    let shell: BoardShell
    let root: NSView
    let window: NSWindow
    let launched: LaunchedArgv
    let suite: String

    func teardown() {
        shell.e2eTeardown()
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

/// A board whose recents store is pre-seeded with `seeding` (host, path) pairs, and
/// whose launches are captured instead of spawned.
@MainActor
private func makeBoard(seeding: [(host: String?, path: String)] = []) -> Board {
    let shell = BoardShell(seeds: [])
    let (defaults, suite) = scratchDefaults()
    shell.recentFoldersDefaults = defaults
    let store = RecentFolderStore(defaults: defaults, key: BoardShell.recentDirsKey)
    for entry in seeding { store.remember(host: entry.host, path: entry.path) }

    let root = shell.buildContentForTesting()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = root
    // A key, ordered-front window is what makes `sendEvent` route a synthetic event.
    window.makeKeyAndOrderFront(nil)

    let launched = LaunchedArgv()
    shell.launchOverrideForTesting = { seed in
        let pty = try! PTYSession(command: ["/bin/cat"])
        try! pty.start()
        let session = Session(projectDir: seed.projectDir, agentType: .claude,
                              pty: pty, state: .running)
        launched.set(seed.command, session: session)
        return session
    }
    return Board(shell: shell, root: root, window: window, launched: launched, suite: suite)
}

/// Open the palette the way the operator does — the real "New task" action — and hand
/// back the mounted view, laid out so hit-testing is meaningful.
@MainActor
private func openPalette(_ board: Board) throws -> CreateCardPalette {
    board.shell.promptAndCreateSession()
    let palette = try #require(board.shell.createPalette)
    board.root.layoutSubtreeIfNeeded()
    return palette
}

private let kReturn: UInt16 = 36
private let kDelete: UInt16 = 51

/// A real key press delivered by the window to its first responder.
@MainActor
private func press(_ keyCode: UInt16, chars: String, in window: NSWindow) {
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: keyCode)!
    window.sendEvent(event)
}

@MainActor
private func returnKey(in window: NSWindow) { press(kReturn, chars: "\r", in: window) }

/// `⌫` on an empty field — the palette's "step back a stage" gesture.
@MainActor
private func backspace(in window: NSWindow) { press(kDelete, chars: "\u{7f}", in: window) }

/// A genuine left-click through real hit-testing and the window's own delivery.
@MainActor
private func click(_ view: NSView, root: NSView, window: NSWindow) throws {
    root.layoutSubtreeIfNeeded()
    let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    let hit = try #require(root.hitTest(center))
    #expect(hit === view, "the row must own its own click point")
    let event = try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
    window.sendEvent(event)
}

@MainActor
private func row(_ palette: CreateCardPalette, titled title: String) throws -> PaletteRow {
    try #require(palette.navRows.first { $0.titleText == title },
                 "no row titled '\(title)' — rows are \(palette.navRows.map(\.titleText))")
}

/// The launched argv with the minted card id blanked, so two independently created
/// cards can be compared for "the same command" without their ids getting in the way.
/// Every card mints its own id AND its own claude conversation; both ride the argv.
private func normalized(_ argv: [String], cardID: UUID) -> [String] {
    argv.map {
        $0.replacingOccurrences(of: cardID.uuidString, with: "<card-id>")
            .replacingOccurrences(
                of: "--session-id [0-9a-f-]{36}", with: "--session-id <conversation>",
                options: .regularExpression)
    }
}

/// What a launch actually produced: the argv, and the session the shell then stamps
/// its remote spec onto (the same spec ``SessionRegistry/snapshotWindows`` persists).
private final class LaunchedArgv: @unchecked Sendable {
    private let lock = NSLock()
    private var command: [String] = []
    private var launchedSession: Session?

    func set(_ argv: [String], session: Session) {
        lock.lock(); command = argv; launchedSession = session; lock.unlock()
    }

    var argv: [String] {
        lock.lock(); defer { lock.unlock() }
        return command
    }

    var recordedSpec: RemoteSpecSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return launchedSession?.remoteSpec.map(RemoteSpecSnapshot.init(spec:))
    }

    /// The conversation id the shell pinned by auto-typing `claude` — nil when the
    /// create path (correctly) typed nothing into the fresh pane.
    var claudeConversation: UUID? {
        lock.lock(); defer { lock.unlock() }
        return launchedSession?.claudeSessionID
    }
}

// MARK: - AC-1

/// TC-E2E-012: the palette opens by asking WHERE, and a host the board already knows is
/// an ordinary row beside "This Mac" — reached from the real "New task" action, picked
/// with a real click. Remote is a first-class choice, not a hidden keystroke.
@MainActor
@Test("TC-E2E-012 / AC-1: the palette opens on a where-does-this-run stage, remote first-class")
func remoteIsAFirstClassChoiceOnTheOpeningStage() throws {
    let board = makeBoard(seeding: [(nil, "/tmp/demo-project"), ("roman@far.invalid", "/srv/app")])
    defer { board.teardown() }

    let palette = try openPalette(board)
    #expect(palette.stage == .destination, "the first question is where this runs")
    #expect(palette.navRows.map(\.titleText).contains("This Mac"))
    let hostRow = try row(palette, titled: "roman@far.invalid")

    try click(hostRow, root: board.root, window: board.window)
    #expect(palette.destination == .remote("roman@far.invalid"))
    #expect(palette.stage == .project, "picking a host advances to its folder stage")
}

// MARK: - AC-2

/// TC-E2E-014: the same path on two boxes is two entries, and neither box's folder ever
/// shows up under the other — or under this Mac. Driven by real clicks across three
/// destinations in one session.
@MainActor
@Test("TC-E2E-014 / AC-2: recents are host-qualified — the same path on two hosts is two entries")
func recentFoldersAreHostQualified() throws {
    let board = makeBoard(seeding: [
        (nil, "/tmp/local-only"), ("a.invalid", "/srv/app"), ("b.invalid", "/srv/app"),
    ])
    defer { board.teardown() }

    let palette = try openPalette(board)
    try click(try row(palette, titled: "a.invalid"), root: board.root, window: board.window)
    #expect(palette.navRows.map(\.titleText) == ["app"], "host A's own folder, and only it")

    backspace(in: board.window)          // ⌫ on the empty folder field steps back
    #expect(palette.stage == .destination)
    try click(try row(palette, titled: "b.invalid"), root: board.root, window: board.window)
    #expect(palette.navRows.map(\.titleText) == ["app"],
            "the SAME path on host B is its own entry, not a shared one")

    backspace(in: board.window)
    try click(try row(palette, titled: "This Mac"), root: board.root, window: board.window)
    let localTitles = palette.navRows.map(\.titleText)
    #expect(localTitles.contains("local-only"))
    #expect(!localTitles.contains("app"), "a remote path never appears under local")
}

/// The pre-US-009 defaults value is a flat `[String]` of local dirs — those entries
/// predate remote cards, so they must decode as local rather than vanish.
@MainActor
@Test("AC-2: the legacy flat recents list decodes as local, and a remote entry can't evict it")
func legacyFlatRecentsDecodeAsLocal() throws {
    let (defaults, suite) = scratchDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    defaults.set(["/tmp/old-project"], forKey: "recents")

    let store = RecentFolderStore(defaults: defaults, key: "recents")
    #expect(store.load() == [PaletteProject(host: nil, path: "/tmp/old-project")])

    store.remember(host: "far.invalid", path: "/srv/app")
    #expect(store.load().filter { $0.host == nil }.map(\.path) == ["/tmp/old-project"])
    #expect(store.load().filter { $0.host == "far.invalid" }.map(\.path) == ["/srv/app"])
}

/// The edge case the story names: a host used for the first time has no folders to
/// list, so hand entry IS the stage — and a blank folder still creates the card (tmux
/// opens the login directory). Nothing is probed, so an unreachable host is no blocker.
@MainActor
@Test("AC-2 edge: a host with no recents yet gives hand entry, not an empty dead end")
func unknownHostFallsBackToHandEntry() throws {
    let board = makeBoard(seeding: [(nil, "/tmp/demo-project")])
    defer { board.teardown() }

    let palette = try openPalette(board)
    palette.hostField.stringValue = "fresh.invalid"
    returnKey(in: board.window)
    #expect(palette.destination == .remote("fresh.invalid"), "a typed host needs no recents")
    #expect(palette.navRows.isEmpty, "no folder is known on this box yet")
    #expect(!palette.fieldBoxes.isEmpty, "…so the stage is hand entry, not an empty list")

    returnKey(in: board.window)          // an empty folder field is legitimate
    #expect(palette.stage == .task)
    palette.nameField.stringValue = "first run"
    returnKey(in: board.window)

    let card = try #require(board.shell.cards.last)
    #expect(card.sessionID == "remote/fresh.invalid/first-run")
    #expect(board.shell.createPalette == nil, "a created card dismisses the palette")
}

// MARK: - AC-3

/// TC-E2E-013: a card created by typing through the palette and a card created the way
/// ⌘⇧R created one are one construction — same spec, same argv (bar the minted id),
/// same identity binding and same restore snapshot.
@MainActor
@Test("TC-E2E-013 / AC-3: a palette card is indistinguishable from an alert-created card")
func paletteCardMatchesTheDirectlyConstructedCard() throws {
    let viaPalette = makeBoard()
    defer { viaPalette.teardown() }

    let palette = try openPalette(viaPalette)
    palette.hostField.stringValue = "roman@far.invalid:2200"
    returnKey(in: viaPalette.window)
    palette.dirField.stringValue = "/srv/app"
    returnKey(in: viaPalette.window)
    #expect(palette.stage == .task)
    palette.nameField.stringValue = "agent"
    returnKey(in: viaPalette.window)
    let fromPalette = try #require(viaPalette.shell.cards.last)

    // The ⌘⇧R construction verbatim: parse the destination, then the shared creator.
    let direct = makeBoard()
    defer { direct.teardown() }
    let spec = try #require(RemoteTmuxSpec.parse(
        destination: "roman@far.invalid:2200", sessionName: "agent", remoteDir: "/srv/app"))
    let fromAlert = try #require(direct.shell.createRemoteTmuxSession(spec: spec))

    #expect(fromPalette.sessionID == fromAlert.sessionID)
    #expect(fromPalette.projectDir == fromAlert.projectDir)
    #expect(fromPalette.agent == fromAlert.agent)
    #expect(normalized(viaPalette.launched.argv, cardID: fromPalette.id)
            == normalized(direct.launched.argv, cardID: fromAlert.id),
            "same ssh + tmux command, down to the exported card id's position")
    // What a quit would persist is the SPEC stamped on the launched session — equal on
    // both paths, so a palette card restores exactly as an alert card did (DD-003).
    #expect(viaPalette.launched.recordedSpec == RemoteSpecSnapshot(spec: spec))
    #expect(viaPalette.launched.recordedSpec == direct.launched.recordedSpec)
}

/// The folder the operator just used is remembered against THAT host, so the next
/// creation offers it — and it stays out of the local list.
@MainActor
@Test("AC-2: creating a remote card remembers its folder under that host, not locally")
func creatingARemoteCardRemembersTheFolderPerHost() throws {
    let board = makeBoard(seeding: [(nil, "/tmp/demo-project")])
    defer { board.teardown() }

    let palette = try openPalette(board)
    palette.hostField.stringValue = "far.invalid"
    returnKey(in: board.window)
    palette.dirField.stringValue = "/srv/app"
    returnKey(in: board.window)
    palette.nameField.stringValue = "agent"
    returnKey(in: board.window)
    #expect(board.shell.cards.count == 1)

    let reopened = try openPalette(board)
    try click(try row(reopened, titled: "far.invalid"), root: board.root, window: board.window)
    #expect(reopened.navRows.map(\.titleText) == ["app"], "the folder came back under its host")

    backspace(in: board.window)
    try click(try row(reopened, titled: "This Mac"), root: board.root, window: board.window)
    #expect(!reopened.navRows.map(\.titleText).contains("app"), "…and only under its host")
}

// MARK: - AC-5

/// TC-E2E-015: the ⌘⇧R alert is gone — its `@objc` menu action no longer exists on the
/// shell, so no menu item can be wired to it — and the palette, now the only route,
/// still produces the remote card from real key events alone.
@MainActor
@Test("TC-E2E-015 / AC-5: the ⌘⇧R alert is retired and the palette is the only route")
func theRemoteAlertIsRetiredAndThePaletteCarriesIt() throws {
    let board = makeBoard()
    defer { board.teardown() }

    #expect(board.shell.responds(to: Selector(("newRemoteTmuxMenuAction"))) == false,
            "the alert's menu action is deleted, so ⌘⇧R can no longer be installed")

    let palette = try openPalette(board)
    palette.hostField.stringValue = "roman@far.invalid"
    returnKey(in: board.window)
    palette.dirField.stringValue = "/srv/app"
    returnKey(in: board.window)
    palette.nameField.stringValue = "agent"
    returnKey(in: board.window)

    let card = try #require(board.shell.cards.last, "the palette alone still creates the card")
    #expect(card.sessionID == "remote/far.invalid/agent")
    #expect(board.launched.argv.first == "/usr/bin/ssh")
}

// MARK: - Windows (psmux) hosts

/// A Windows box on plain OpenSSH: the operator flips ONE toggle on the folder stage
/// (a real dispatched click) and the whole card family follows — the launched argv
/// speaks psmux instead of tmux, no `claude` is auto-typed at what is really a
/// password prompt, the spec persists its kind for restore, and the board remembers
/// the host so the toggle comes pre-checked next time.
@MainActor
@Test("a Windows host toggled on speaks psmux, starts claude far-side, and is remembered")
func windowsToggleMakesAPsmuxTerminalOnlyCard() throws {
    let board = makeBoard()
    defer { board.teardown() }

    let palette = try openPalette(board)
    palette.hostField.stringValue = "roman@winbox.invalid"
    returnKey(in: board.window)
    let toggle = try #require(palette.windowsToggleForTesting, "the folder stage offers the host-type toggle")
    #expect(!toggle.isOn, "POSIX is the default — Windows is an opt-in")
    try click(toggle, root: board.root, window: board.window)
    #expect(toggle.isOn, "a genuine leftMouseDown flips it on")
    palette.dirField.stringValue = #"C:\Dev\app"#
    returnKey(in: board.window)
    palette.nameField.stringValue = "agent"
    returnKey(in: board.window)

    let card = try #require(board.shell.cards.last, "the windows card was created")
    #expect(card.sessionID == "remote/winbox.invalid/agent")
    let conversation = try #require(board.launched.claudeConversation,
                                    "the conversation id exists — it rides the argv, not keystrokes")
    #expect(board.launched.argv.last
            == "psmux -CC new-session -A -s agent -e SICH_CARD_ID=\(card.id.uuidString)"
            + #" -c "C:\Dev\app""#
            + " -- powershell -NoExit -Command claude --session-id "
            + conversation.uuidString.lowercased(),
            "the far-side command is psmux tokens starting claude, nothing POSIX, nothing typed")
    #expect(board.launched.recordedSpec?.hostKind == .windowsPsmux,
            "the kind rides the persisted spec, so a restore re-emits psmux")

    // The choice sticks per host: reopening on the same box pre-checks the toggle.
    let reopened = try openPalette(board)
    reopened.hostField.stringValue = "roman@winbox.invalid"
    returnKey(in: board.window)
    #expect(try #require(reopened.windowsToggleForTesting).isOn, "the board remembers a Windows host")
}
