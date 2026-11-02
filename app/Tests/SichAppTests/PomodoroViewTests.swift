import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// The pomodoro in the app: the ring's readings, the dock under the gauges, the rest
/// overlay, and the shell wiring between them and the board. Interaction ACs are
/// driven by REAL `NSEvent`s dispatched to the hit-tested view (Interaction-AC
/// Binding Rule), never by calling the handler.
@MainActor
@Suite(.serialized)
struct PomodoroViewTests {

    // MARK: - Ring (pure readings)

    @Test("the ring reads the engine state: idle / focus / paused / break / hold / over")
    func ringLooks() {
        var state = PomodoroState()
        #expect(PomodoroRingView.look(for: state) == .idle)
        #expect(PomodoroRingView.phaseText(for: state) == "start a pomodoro")

        state.phase = .work
        state.isRunning = true
        state.remaining = 20 * 60
        state.total = 25 * 60
        #expect(PomodoroRingView.look(for: state) == .work(attention: 0))
        #expect(PomodoroRingView.phaseText(for: state) == "focus")

        state.remaining = 90   // inside the last three minutes: half-way to orange
        if case .work(let attention) = PomodoroRingView.look(for: state) {
            #expect(abs(attention - 0.5) < 0.01)
        } else {
            Issue.record("still a work look")
        }

        state.isRunning = false
        #expect(PomodoroRingView.look(for: state) == .paused)
        #expect(PomodoroRingView.phaseText(for: state) == "paused")

        state.awaitingReply = true
        #expect(PomodoroRingView.look(for: state) == .hold)
        #expect(PomodoroRingView.phaseText(for: state) == "break waits for ↵")

        state = PomodoroState()
        state.phase = .longBreak
        state.isRunning = true
        #expect(PomodoroRingView.look(for: state) == .rest)
        #expect(PomodoroRingView.phaseText(for: state) == "long break")
        state.breakOver = true
        #expect(PomodoroRingView.look(for: state) == .over)
        #expect(PomodoroRingView.phaseText(for: state) == "break over")
    }

    @Test("the dial's arc is the fraction left and idle shows the full 25:00 with no arc")
    func ringGeometry() {
        let ring = PomodoroRingView(diameter: 168)
        ring.apply(PomodoroState())
        #expect(ring.digitsForTesting == "25:00")
        #expect(ring.arcHiddenForTesting, "idle: dashed track only")
        #expect(ring.phaseForTesting == "START A POMODORO")

        var state = PomodoroState()
        state.phase = .work
        state.isRunning = true
        state.total = 25 * 60
        state.remaining = 12 * 60 + 30
        ring.apply(state)
        #expect(ring.digitsForTesting == "12:30")
        #expect(!ring.arcHiddenForTesting)
        #expect(abs(ring.arcFractionForTesting - 0.5) < 0.001)
    }

    // MARK: - Dock

    @Test("the dock's lines: on <card> · +N more, the cycle dots, the tally, rest now, held count")
    func dockLines() {
        let dock = PomodoroDock(compact: false)
        var state = PomodoroState()
        dock.render(state: state, context: .init())
        #expect(dock.onCardTextForTesting == "tags the card you're in")
        #expect(dock.tallyForTesting == "0 today · 0m")
        #expect(dock.restNowForTesting.isHidden, "nothing to end while idle")
        #expect(dock.heldTextForTesting == nil)

        state.phase = .work
        state.isRunning = true
        state.cardID = UUID()
        state.touched = [state.cardID!, UUID(), UUID()]
        state.completed = 2
        state.focusToday = 75 * 60
        state.held = [UUID(), UUID()]
        dock.render(state: state, context: .init(cardTitle: "Fix the login redirect"))
        #expect(dock.onCardTextForTesting == "on Fix the login redirect · +2 more")
        #expect(PomodoroDock.dotsText(state) == "● ● ◐ ○")
        #expect(dock.tallyForTesting == "2 today · 1h 15m")
        #expect(!dock.restNowForTesting.isHidden)
        #expect(dock.heldTextForTesting == "2 will need you after this pomodoro")
        #expect(dock.hintForTesting.isHidden, "no advice without a hint")

        dock.render(state: state, context: .init(cardTitle: nil, hint: .allAgentsWorking))
        #expect(dock.onCardTextForTesting == "no card — drill in to tag one")
        #expect(!dock.hintForTesting.isHidden)
        #expect(dock.hintForTesting.stringValue == "all agents working — rest now?")
    }

    @Test("the quota panel hosts the dock: full under the gauges on the trailing edge, compact on the bottom strip")
    func quotaPanelHostsDock() {
        let panel = QuotaPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        #expect(panel.pomodoroDock.ring.diameter == 168)
        #expect(panel.pomodoroDock.isDescendant(of: panel))
        panel.dock = .bottom(columns: 3)
        #expect(panel.pomodoroDock.ring.diameter == 112, "compact ring on the strip")
        #expect(panel.pomodoroDock.isDescendant(of: panel), "re-docking re-mounts the dock")
    }

    // MARK: - Shell wiring (real events)

    @Test("clicking the ring on the board starts a pomodoro; clicking again pauses it")
    func ringClickStartsAndPauses() throws {
        let shell = BoardShell(seeds: Self.seeds())
        let root = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        let window = Self.window(for: root)
        defer { window.orderOut(nil) }

        #expect(shell.pomodoro.state.phase == .idle)
        try Self.click(shell.quota.pomodoroDock.ring, in: root, window: window)
        #expect(shell.pomodoro.state.phase == .work, "the ring click started a pomodoro")
        #expect(shell.pomodoro.state.isRunning)
        #expect(shell.pomodoro.state.cardID == nil, "from the board nothing is tagged yet")

        try Self.click(shell.quota.pomodoroDock.ring, in: root, window: window)
        #expect(shell.pomodoro.state.phase == .work)
        #expect(!shell.pomodoro.state.isRunning, "the second click paused it")
    }

    @Test("every card you drill into during a pomodoro takes the minutes from there")
    func drillInTagsAndReadsOut() throws {
        let shell = BoardShell(seeds: Self.seeds(count: 2))
        _ = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        shell.pomodoro.now = { now }

        shell.pomodoro.start(cardID: nil)
        let first = shell.cards[0]
        let second = shell.cards[1]
        shell.drill(into: first)
        #expect(shell.pomodoro.state.cardID == first.id, "the card you're in gets the minutes")

        now = now.addingTimeInterval(5 * 60)
        shell.pomodoro.tick()
        #expect(shell.pomodoro.state.humanTime(for: first.id) == 5 * 60)

        shell.returnToBoard()
        shell.drill(into: second)
        now = now.addingTimeInterval(3 * 60)
        shell.pomodoro.tick()
        #expect(shell.pomodoro.state.humanTime(for: first.id) == 5 * 60)
        #expect(shell.pomodoro.state.humanTime(for: second.id) == 3 * 60)
        #expect(shell.pomodoro.state.touched == [first.id, second.id])
        #expect(shell.quota.pomodoroDock.onCardTextForTesting.hasSuffix(" · +1 more"))
    }

    @Test("rest now › starts the break: the rest overlay comes up over the window, end break early takes it down")
    func restNowAndEndEarly() throws {
        let shell = BoardShell(seeds: Self.seeds())
        let root = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        let window = Self.window(for: root)
        defer { window.orderOut(nil) }
        shell.pomodoro.start(cardID: nil)
        #expect(shell.restOverlay.isHidden)

        try Self.click(shell.quota.pomodoroDock.restNowForTesting, in: root, window: window)
        #expect(shell.pomodoro.state.phase == .shortBreak, "rest now ends the work phase")
        #expect(!shell.restOverlay.isHidden, "the break blurs the board")
        #expect(shell.restOverlay.heldTextForTesting == "nothing needs you")
        #expect(shell.restOverlay.agentsTextForTesting == "1 agent still working underneath")

        try Self.click(shell.restOverlay.earlyPillForTesting, in: root, window: window)
        #expect(shell.pomodoro.state.phase == .idle)
        #expect(shell.restOverlay.isHidden, "ending the break uncovers the board")
    }

    @Test("a card that starts needing you mid-pomodoro is held: drawn like any other card, listed on the break-over tray, and picking it starts the next pomodoro on it")
    func heldCardsAndTray() throws {
        let shell = BoardShell(seeds: Self.seeds(count: 2))
        let root = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        let window = Self.window(for: root)
        defer { window.orderOut(nil) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        shell.pomodoro.now = { now }
        let working = shell.cards[0]
        let other = shell.cards[1]

        shell.pomodoro.start(cardID: working.id)
        shell.move(cardID: other.id, to: .waitingForInput)
        #expect(shell.pomodoro.state.held == [other.id], "the other card waits its turn")
        let face = try #require(Self.cardView(for: other.id, in: shell))
        #expect(face.alphaValue == 1, "held is quiet, never a tint on the card")
        #expect(shell.pomodoro.allowsStandup == false, "no standup mid-pomodoro")

        // Going into the held card to answer it is working on it: it is released.
        shell.drill(into: other)
        #expect(shell.pomodoro.state.held.isEmpty, "the card you are in is never held")
        #expect(shell.pomodoro.state.cardID == other.id)
        shell.returnToBoard()
        shell.move(cardID: other.id, to: .running)
        shell.move(cardID: other.id, to: .waitingForInput)
        #expect(shell.pomodoro.state.held.isEmpty, "still yours — asking again does not hold it")
        shell.drill(into: working)
        shell.returnToBoard()
        shell.move(cardID: other.id, to: .running)
        shell.move(cardID: other.id, to: .waitingForInput)
        #expect(shell.pomodoro.state.held == [other.id], "back on the first card, the other one waits again")

        // The work phase and then the break run out.
        now = now.addingTimeInterval(PomodoroConstants.work + 1)
        shell.pomodoro.tick()
        #expect(shell.pomodoro.state.phase == .shortBreak)
        #expect(shell.restOverlay.heldTextForTesting == "1 task will need you after the break")
        now = now.addingTimeInterval(PomodoroConstants.shortBreak + 1)
        shell.pomodoro.tick()
        #expect(shell.pomodoro.state.breakOver)
        #expect(shell.restOverlay.isOver)
        let rows = shell.restOverlay.trayRowsForTesting
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.row.cardID == other.id)

        try Self.click(row, in: root, window: window)
        #expect(shell.drilledInCardID == other.id, "the tray row drills into the card")
        #expect(shell.pomodoro.state.phase == .work)
        #expect(shell.pomodoro.state.cardID == other.id, "and the next pomodoro counts toward it")
        #expect(shell.pomodoro.state.held.isEmpty)
        #expect(shell.restOverlay.isHidden)
    }

    @Test("a typed, unsent reply holds the break until ↵ — real key events into the drilled-in terminal")
    func holdForReply() throws {
        let shell = BoardShell(seeds: Self.seeds())
        let root = shell.buildContentForTesting()
        defer { shell.e2eTeardown() }
        let window = Self.window(for: root)
        defer { window.orderOut(nil) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        shell.pomodoro.now = { now }
        let card = try #require(shell.cards.first)
        shell.pomodoro.start(cardID: card.id)
        shell.drill(into: card)
        let surface = try #require(shell.drillIn.surfaceForTesting)

        surface.keyDown(with: try Self.key("y", code: 16, window: window))
        #expect(surface.hasUnsentInput)
        now = now.addingTimeInterval(PomodoroConstants.work + 1)
        shell.pomodoro.tick()
        #expect(shell.pomodoro.state.awaitingReply, "mid-reply: the break waits for ↵")
        #expect(shell.pomodoro.state.phase == .work)
        #expect(shell.restOverlay.isHidden)

        surface.keyDown(with: try Self.key("\r", code: 36, window: window))
        #expect(shell.pomodoro.state.awaitingReply == false)
        #expect(shell.pomodoro.state.phase == .shortBreak, "↵ sent the reply: rest begins")
        #expect(!shell.restOverlay.isHidden)
    }

    @Test("the state survives a relaunch: a saved running phase is caught up on attach")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-pomodoro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        let first = PomodoroController()
        first.now = { t0 }
        first.attach(store: PomodoroStore(directory: dir))
        first.start(cardID: nil)

        let second = PomodoroController()
        second.now = { t0.addingTimeInterval(10 * 60) }
        second.attach(store: PomodoroStore(directory: dir))
        #expect(second.state.phase == .work)
        #expect(abs(second.state.remaining - 15 * 60) < 1, "ten minutes passed while closed")
    }

    // MARK: - Helpers

    static func seeds(count: Int = 1) -> [BoardSeed] {
        (0..<count).map {
            BoardSeed(sessionID: "t\($0)", projectDir: "~/x\($0)", agent: .claude,
                      state: .running, scrollback: "")
        }
    }

    static func window(for root: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        return window
    }

    /// A genuine left-mouse-down at the view's centre, dispatched to whatever the
    /// window's hit test resolves there — RED if anything covers the control.
    static func click(_ target: NSView, in root: NSView, window: NSWindow) throws {
        root.layoutSubtreeIfNeeded()
        #expect(target.bounds.width > 0 && target.bounds.height > 0, "control has a size")
        let center = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let hit = try #require(root.hitTest(center))
        #expect(hit === target, "the control must own its click point, got \(type(of: hit))")
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        hit.mouseDown(with: event)
    }

    static func key(_ chars: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }

    static func cardView(for id: UUID, in shell: BoardShell) -> SessionCard? {
        for group in BoardView.ColumnGroup.allCases {
            if let cell = shell.boardView.cellForTesting(group),
               let face = cell.arrangedSubviews.compactMap({ $0 as? SessionCard }).first(where: { $0.card.id == id }) {
                return face
            }
        }
        return nil
    }
}
