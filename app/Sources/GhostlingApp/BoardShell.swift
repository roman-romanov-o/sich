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

    private var window: NSWindow?
    // Internal (not private) so a real view-level test can assert the drill-in
    // hierarchy — the iter-2 sign-off proved BoardSelection's value-type test does
    // not cover whether the board is actually hidden / restored on screen.
    let boardView = BoardView()
    let attention = AttentionIndicator()
    let drillIn = DrillInPanel()

    private var selection = BoardSelection()
    private(set) var cards: [BoardCard] = []
    private var ptyByCard: [UUID: PTYSession] = [:]

    /// - Parameter seeds: the sessions to populate the board with (defaults to the
    ///   demo spread used for screenshots). Each launches a firewall-clean fake
    ///   agent — never `claude -p`.
    public init(seeds: [BoardSeed] = BoardSeed.demo) {
        self.seeds = seeds
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        seedSessions()
        makeWindow()
        wireInteractions()
        refresh()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
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
                sessionID: seed.sessionID, projectDir: seed.projectDir,
                agent: seed.agent, flow: seed.flow, state: seed.state
            )
            cards.append(card)
            ptyByCard[card.id] = session.pty
        }
    }

    private func launch(_ seed: BoardSeed) -> Session? {
        try? registry.launch(
            command: seed.command,
            projectDir: seed.projectDir,
            agentType: AgentType(rawValue: seed.agent.rawValue) ?? .shell,
            flowTag: seed.flow == .a ? .backlog : .interactive
        )
    }

    // MARK: - Window

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Ghostling — mission control"
        window.contentView = makeContentView(in: window.frame.size)
        window.center()
        window.makeKeyAndOrderFront(nil)
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
        layout(boardView, in: root, header: false)
        drillIn.isHidden = true
        layoutDrillIn(in: root)
        return root
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
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
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
        attention.onActivate = { [weak self] in self?.activateAttention() }
        drillIn.onClose = { [weak self] in self?.returnToBoard() }
    }

    /// US-002: drill into a card → full-window terminal takeover (Altitude-1).
    /// The board surface and attention header are hidden so the embedded terminal
    /// is the only thing on screen.
    func drill(into card: BoardCard) {
        guard let pty = ptyByCard[card.id] else { return }
        selection.focus(card.id)
        boardView.isHidden = true
        attention.isHidden = true
        drillIn.isHidden = false
        drillIn.focus(card: card, pty: pty)
    }

    /// US-002 AC#2: return to the board, state preserved — un-hide the board and
    /// attention header so the board looks exactly as it did before drilling in.
    func returnToBoard() {
        selection.returnToBoard()
        boardView.isHidden = false
        attention.isHidden = false
        drillIn.isHidden = true
        refresh()
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
        attention.update(count: Attention.count(cards))
        boardView.render(cards: selection.visibleCards(from: cards))
    }
}
