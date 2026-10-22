import AppKit
import SichCore

/// The mission-control board surface (US-003), in the Mission Control v5 layout:
/// six live columns — QUEUE / PARKED / WORKING / NEEDS YOU / BLOCKED / DONE —
/// instead of raw state columns × flow swimlanes. DONE can be folded into a
/// narrow rail (``DoneRail``) so a laptop-width board spends its width on the
/// three live columns; the fold persists across launches. Flow is card
/// metadata now (the harness badge + an "auto" marker on autonomous
/// cards only), not a lane.
///
/// It is a projection of a `[BoardCard]` snapshot: ``render(cards:)`` lays the
/// cards out by attention group. Live column moves come from the host re-calling
/// `render`. Three callbacks bubble up: ``onSelect`` (drill-in, US-002),
/// ``onCreate`` (the add-task icon), and ``onMove`` (a card dragged
/// to a new column → manual state change).
@MainActor
final class BoardView: NSView {
    /// Drill-in: a card was clicked (US-002 AC#1). The host focuses its terminal.
    var onSelect: ((BoardCard) -> Void)?
    /// The add-task icon was tapped — the host launches a live card.
    var onCreate: (() -> Void)?
    /// A card was dropped on a column — the host moves it (manual state change).
    var onMove: ((UUID, BoardColumn) -> Void)?
    /// A card's "Rename Task…" context item was picked — the host prompts + renames.
    var onRename: ((BoardCard) -> Void)?
    /// A card's "Delete Task…" context item was picked — the host confirms, tears
    /// down the session + its worktree, and removes the card.
    var onDelete: ((BoardCard) -> Void)?
    /// Switch the card to another account on the same harness.
    var onSwitchAccount: ((BoardCard, UUID) -> Void)?
    /// Continue the task on a different harness with a context handoff.
    var onSwitchHarness: ((BoardCard, CardAgent) -> Void)?
    /// Rule 1: defer a NEEDS YOU card to queue until tomorrow.
    var onDeferNeedsYou: ((BoardCard) -> Void)?
    /// The archive icon beside DONE was tapped — the host opens the archive page.
    var onShowArchive: (() -> Void)?

    /// The v5 column groups, left→right.
    enum ColumnGroup: CaseIterable {
        case queue, parked, working, needsYou, blocked, done

        /// Every `CardState` lands in exactly one group — total, so no card can
        /// silently vanish from the board (the `.unknown` regression).
        static func group(for state: CardState) -> ColumnGroup {
            switch state {
            case .waitingForInput: return .needsYou
            case .blocked: return .blocked
            case .running, .runningTests: return .working
            case .parked: return .parked
            // `unreachable` is explicitly NOT `.working`: the whole point is that a
            // link we cannot read must stop looking like progress (US-007 AC-3).
            case .idle: return .queue
            case .unknown, .unreachable: return .parked
            case .done: return .done
            }
        }

        var title: String {
            switch self {
            case .queue: return "QUEUE"
            case .parked: return "PARKED"
            case .working: return "WORKING"
            case .needsYou: return "NEEDS YOU"
            case .blocked: return "BLOCKED"
            case .done: return "DONE"
            }
        }

        /// The state a manual drop into this group sets, expressed as the
        /// representative `BoardColumn` (the host's `onMove` contract).
        var dropColumn: BoardColumn {
            switch self {
            case .queue: return .idle
            case .parked: return .parked
            case .working: return .running
            case .needsYou: return .waitingForInput
            case .blocked: return .blocked
            case .done: return .done
            }
        }

        /// The pulsing status dot next to the header — only the live columns get one.
        @MainActor var dotColor: NSColor? {
            switch self {
            case .needsYou: return BoardTheme.attention
            case .working: return BoardTheme.stateColor(.running)
            case .blocked: return BoardTheme.stateColor(.blocked)
            case .queue, .parked, .done: return nil
            }
        }
    }

    /// Where the DONE fold choice lives; tests hand in a throwaway suite.
    private let defaults: UserDefaults
    private static let doneCollapsedKey = "board.doneCollapsed"
    /// Width of the DONE column while collapsed — just the header chrome, stacked.
    static let doneRailWidth: CGFloat = 44

    /// DONE folded into a narrow rail so the three live columns get its width.
    /// Finished cards are still counted there; expand to read or drop onto them.
    private(set) var isDoneCollapsed: Bool

    /// An unfolded DONE column's width as a share of a live column's while narrow.
    static let narrowDoneRatio: CGFloat = 0.7

    /// Portrait windows have no width to spare: DONE — history, not work — gives
    /// up part of its column to the live ones. The shell drives this from the
    /// window shape; the fold above stays the operator's own, stronger choice.
    var isDoneNarrow = false {
        didSet {
            guard isDoneNarrow != oldValue else { return }
            applyFontScale()
        }
    }

    private let groups = ColumnGroup.allCases
    private var cells: [ColumnGroup: BoardCell] = [:]
    /// Cards in render order (QUEUE column top→bottom, then WORKING, …) — the
    /// linear path arrow keys walk. Rebuilt on every render; focus re-found by id.
    private var orderedCards: [SessionCard] = []
    private var focusedCardID: UUID?
    /// Per-column count captions, updated on every render.
    private var countLabels: [ColumnGroup: NSTextField] = [:]
    /// What a lane's emptiness toggles: its column surface, caps title and dot.
    private var laneViews: [ColumnGroup: (column: NSView, title: NSTextField, dot: NSView?)] = [:]
    /// Every column view, folded DONE rail included, in board order.
    private var columnViews: [ColumnGroup: NSView] = [:]
    /// Each lane's header row — its width is what an empty lane shrinks to.
    private var laneHeaders: [ColumnGroup: NSView] = [:]
    /// The lanes currently drawn at header width, and the width constraints that
    /// put them there. Re-solved only when the set of empty lanes changes.
    private var compactLanes: Set<ColumnGroup>?
    private var laneWidthConstraints: [NSLayoutConstraint] = []
    private var lastCards: [BoardCard] = []
    private var lastQuotaBlocks: [UUID: CardQuotaBlock] = [:]
    private var lastSwitchMenus: [UUID: CardSwitchMenu] = [:]
    /// What each cell was last populated from — the render diff's memory. Cleared
    /// whenever the scaffold (and thus every cell) is rebuilt.
    private var columnFaces: [ColumnGroup: [CardFace]] = [:]
    init(frame frameRect: NSRect = .zero, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isDoneCollapsed = defaults.bool(forKey: Self.doneCollapsedKey)
        super.init(frame: frameRect)
        themedBackground = BoardTheme.canvas
        buildScaffold()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Scaffold (built once): four equal columns filling the surface

    private func buildScaffold() {
        subviews.forEach { $0.removeFromSuperview() }
        constraints.forEach { $0.isActive = false }
        cells = [:]
        countLabels = [:]
        laneViews = [:]
        columnViews = [:]
        laneHeaders = [:]
        compactLanes = nil
        laneWidthConstraints = []
        columnFaces = [:]
        var previous: NSView?
        // QUEUE → PARKED → WORKING → NEEDS YOU → BLOCKED → DONE. The unfinished
        // backlog UI stays out of this live-work surface.
        for group in groups {
            let collapsed = group == .done && isDoneCollapsed
            let column = collapsed ? makeDoneRail() : makeColumn(group)
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: topAnchor),
                column.bottomAnchor.constraint(equalTo: bottomAnchor),
                column.leadingAnchor.constraint(
                    equalTo: previous?.trailingAnchor ?? leadingAnchor),
            ])
            if collapsed {
                column.widthAnchor.constraint(equalToConstant: Self.doneRailWidth).isActive = true
            }
            columnViews[group] = column
            previous = column
        }
        previous?.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        applyLaneWidths(compact: [])
    }

    /// Lane widths. A lane with cards shares the free width equally with the other
    /// occupied lanes (DONE at ``narrowDoneRatio`` in a portrait window); an EMPTY
    /// lane shrinks to its header, so an idle NEEDS YOU no longer costs a busy
    /// QUEUE its width — the wrapping and truncation on real boards came from that.
    /// A board with every lane empty keeps the even split (nothing to favour).
    private func applyLaneWidths(compact requested: Set<ColumnGroup>) {
        let live = groups.filter { !(isDoneCollapsed && $0 == .done) }
        let compact = requested.count >= live.count ? [] : requested
        guard compact != compactLanes else { return }
        compactLanes = compact
        NSLayoutConstraint.deactivate(laneWidthConstraints)
        laneWidthConstraints = []
        var anchor: NSView?
        for group in live {
            guard let column = columnViews[group] else { continue }
            if compact.contains(group), let header = laneHeaders[group] {
                let gutter: CGFloat = group == .done && isDoneNarrow ? 10 : 20
                let width = ceil(header.fittingSize.width) + gutter * 2
                laneWidthConstraints.append(column.widthAnchor.constraint(equalToConstant: width))
            } else if let anchor {
                let ratio = group == .done && isDoneNarrow ? Self.narrowDoneRatio : 1
                laneWidthConstraints.append(column.widthAnchor.constraint(
                    equalTo: anchor.widthAnchor, multiplier: ratio))
            } else {
                anchor = column
            }
        }
        NSLayoutConstraint.activate(laneWidthConstraints)
    }

    private func makeColumn(_ group: ColumnGroup) -> NSView {
        let column = NSView()
        column.wantsLayer = true
        // NEEDS YOU / BLOCKED take their tint from ``applyLaneTone`` once their
        // count is known; PARKED is always the quiet sunken shelf.
        if group == .parked { column.themedBackground = BoardTheme.parkedColumn }
        if group != .done { addRightHairline(to: column) }

        // A narrow DONE spends its little width on the cards, not the gutters.
        let gutter: CGFloat = group == .done && isDoneNarrow ? 10 : 20
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: column.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: gutter),
            stack.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -gutter),
            stack.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])

        let header = columnHeader(group, column: column)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let cell = BoardCell(column: group.dropColumn)
        cell.onDrop = { [weak self] id, col in self?.onMove?(id, col) }
        cells[group] = cell
        let scroll = columnScroll(around: cell)
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // The scroll region reaches the column bottom so the whole column stays a
        // drop target; surplus cards scroll instead of clipping off-screen.
        scroll.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -20).isActive = true
        return column
    }

    /// Wrap a column's card container in a transparent vertical scroller: cards
    /// beyond the window height were simply unreachable before — now they scroll.
    /// The cell is kept at least clip-view tall so an empty column bottom still
    /// accepts drops, and having no intrinsic height of its own the scroll view
    /// also stops a tall column from propping the window open.
    private func columnScroll(around cell: BoardCell) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = cell
        cell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cell.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            cell.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            cell.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            cell.heightAnchor.constraint(
                greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        return scroll
    }

    /// The collapsed DONE column (see ``DoneRail``). No cell — finished cards are
    /// not laid out while folded, so nothing here is a drop target.
    private func makeDoneRail() -> NSView {
        let rail = DoneRail(toggle: doneToggleButton(), archive: archiveButton())
        countLabels[.done] = rail.countLabel
        return rail
    }

    /// The DONE fold control: a chevron pointing the way the column will go.
    private func doneToggleButton() -> NSButton {
        let description = isDoneCollapsed ? "Expand DONE" : "Collapse DONE"
        return BoardSymbolButton.make(
            symbol: isDoneCollapsed ? "chevron.left" : "chevron.right", pointSize: 13,
            tint: BoardTheme.textFaint, identifier: "done-collapse-toggle",
            description: description, target: self, action: #selector(doneToggleTapped))
    }

    @objc private func doneToggleTapped() { setDoneCollapsed(!isDoneCollapsed) }

    /// Fold or unfold DONE. Persists the choice and rebuilds the scaffold (the
    /// same reflow a zoom step pays), re-rendering the last snapshot into it.
    func setDoneCollapsed(_ collapsed: Bool) {
        isDoneCollapsed = collapsed
        defaults.set(collapsed, forKey: Self.doneCollapsedKey)
        buildScaffold()
        render(cards: lastCards)
    }

    /// Centered lane signage: dot + TITLE + count travel as one cluster (a
    /// centered title with the count still glued to the right edge would read
    /// as two disconnected floats). Equal-width spacers do the centering.
    private func columnHeader(_ group: ColumnGroup, column: NSView) -> NSView {
        let row = NSStackView()
        row.spacing = 8
        // Six columns × the row's inter-item spacing would otherwise set a hard
        // window-width floor; clip the header instead of refusing a shrink.
        row.setClippingResistancePriority(.init(490), for: .horizontal)
        let lead = NSView()
        let trail = NSView()
        row.addArrangedSubview(lead)
        let dot = group.dotColor.map { stateDot($0, pulses: group == .needsYou) }
        if let dot { row.addArrangedSubview(dot) }
        let title = label(group.title, font: BoardTheme.columnTitle, color: BoardTheme.textMuted)
        row.addArrangedSubview(title)
        laneViews[group] = (column, title, dot)
        laneHeaders[group] = row
        applyLaneTone(group, count: 0)
        let count = label("", font: BoardTheme.numeric, color: BoardTheme.textFaint)
        countLabels[group] = count
        row.addArrangedSubview(count)
        if group == .queue { row.addArrangedSubview(createButton()) }
        if group == .done {
            row.addArrangedSubview(archiveButton())
            row.addArrangedSubview(doneToggleButton())
        }
        row.addArrangedSubview(trail)
        lead.widthAnchor.constraint(equalTo: trail.widthAnchor).isActive = true
        // One fixed height for every lane: QUEUE's + and DONE's icons would
        // otherwise make those two headers taller and drop their titles below
        // the other columns' baseline.
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return row
    }

    /// The lane dot. Only NEEDS YOU breathes — it is the one header that asks
    /// for the operator; WORKING's cards already carry their own live pulse and
    /// BLOCKED is static by definition, so motion there was just noise.
    private func stateDot(_ color: NSColor, pulses: Bool) -> NSView {
        let dot = NSView()
        dot.themedBackground = color
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        guard pulses, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return dot }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 1.2
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
        return dot
    }

    /// A large, familiar add symbol beside QUEUE: new work enters the board here.
    /// The tooltip and accessibility label preserve the text cue without spending
    /// a second row on visible helper copy.
    private func createButton() -> NSButton {
        BoardSymbolButton.make(
            symbol: "plus.circle.fill", pointSize: 17, tint: BoardTheme.brand,
            identifier: "add-task", description: "Add task",
            target: self, action: #selector(createTapped))
    }

    @objc private func createTapped() { onCreate?() }

    /// The way OUT of the board's history: finished work leaves for the archive on
    /// the next launch, and this icon beside DONE is where the operator reads it.
    private func archiveButton() -> NSButton {
        BoardSymbolButton.make(
            symbol: "archivebox", pointSize: 15, tint: BoardTheme.textFaint,
            identifier: "show-archive", description: "View archived tasks",
            target: self, action: #selector(archiveTapped))
    }

    @objc private func archiveTapped() { onShowArchive?() }

    private func addRightHairline(to column: NSView) {
        let line = NSView()
        line.themedBackground = BoardTheme.hairline
        line.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(line)
        NSLayoutConstraint.activate([
            line.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            line.topAnchor.constraint(equalTo: column.topAnchor),
            line.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    // MARK: - Render (called on every state change → live column moves)

    /// Everything a card view's face is built from: the card itself plus the host
    /// chip reading, which lives OUTSIDE the card (`RemoteHookStatus`). When a
    /// column's faces are unchanged, its existing views are provably identical to
    /// what a rebuild would produce, so the cell is left alone.
    private struct CardFace: Equatable {
        let card: BoardCard
        let chip: HostChipStatus?
        let quotaBlock: CardQuotaBlock
        let switchMenu: CardSwitchMenu

        // Spelled out rather than synthesized: periphery cannot see a synthesized
        // == read the fields and would flag them assign-only.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.card == rhs.card && lhs.chip == rhs.chip
                && lhs.quotaBlock == rhs.quotaBlock && lhs.switchMenu == rhs.switchMenu
        }
    }

    /// Project a card snapshot onto the columns. Only columns whose cards changed
    /// are repopulated — with a deep DONE/QUEUE ledger, tearing down and rebuilding
    /// every card view (labels, layers, tracking areas, a heartbeat animation, a
    /// duration timer each) on every live state flap of ONE active agent made the
    /// whole app drag. Repopulating a changed cell is still the live-column-move
    /// mechanism (US-003 AC#3).
    func render(
        cards: [BoardCard],
        quotaBlocks: [UUID: CardQuotaBlock] = [:],
        switchMenus: [UUID: CardSwitchMenu] = [:]
    ) {
        lastCards = cards
        lastQuotaBlocks = quotaBlocks
        lastSwitchMenus = switchMenus
        var byGroup: [ColumnGroup: [BoardCard]] = [:]
        for card in cards {
            byGroup[ColumnGroup.group(for: card.state), default: []].append(card)
        }
        for group in groups {
            renderColumn(group, cards: byGroup[group] ?? [])
            let count = byGroup[group]?.count ?? 0
            countLabels[group]?.stringValue = countCaption(group, count: count)
            applyLaneTone(group, count: count)
        }
        applyLaneWidths(compact: Set(groups.filter { (byGroup[$0] ?? []).isEmpty }))
        // Keyboard order follows the model snapshot order. Visual placement still
        // happens by column above, but arrow-key traversal stays stable across live
        // state moves so focus does not jump when a card changes columns.
        orderedCards = orderedViews(for: cards)
        restoreKeyboardFocus()
    }

    /// An empty lane is quiet (US-005 AC#3, no false alarm): no tinted surface,
    /// no dot, a muted title. NEEDS YOU and BLOCKED only light up — tint, coloured
    /// title, live dot — while they actually hold a card.
    private func applyLaneTone(_ group: ColumnGroup, count: Int) {
        guard let lane = laneViews[group] else { return }
        let active = count > 0
        lane.dot?.isHidden = !active
        let titleColor: NSColor = switch (group, active) {
        case (.needsYou, true): BoardTheme.attention
        case (.blocked, true): BoardTheme.stateColor(.blocked)
        default: BoardTheme.textMuted
        }
        // Only the colour changes here; the caps keep the font the header was built
        // with, so a re-tone never resizes one title out of step with its count.
        let caps = NSMutableAttributedString(
            attributedString: BoardTheme.caps(group.title, color: titleColor))
        if let font = lane.title.font {
            caps.addAttribute(.font, value: font, range: NSRange(location: 0, length: caps.length))
        }
        lane.title.attributedStringValue = caps
        switch group {
        case .needsYou: lane.column.themedBackground = active ? BoardTheme.needsYouColumn : nil
        case .blocked: lane.column.themedBackground = active ? BoardTheme.blockedColumn : nil
        default: break
        }
    }

    private func renderColumn(_ group: ColumnGroup, cards: [BoardCard]) {
        guard let cell = cells[group] else { return }
        let faces = cards.map(face)
        guard columnFaces[group] != faces else { return }
        // Cards new to this lane since its last render have just moved here (or were
        // just created). A freshly built scaffold has no "last render" — launch and
        // zoom rebuilds stay still.
        let previous = columnFaces[group].map { Set($0.map(\.card.id)) }
        columnFaces[group] = faces
        cell.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for card in cards {
            let view = cardView(card)
            cell.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            if let previous, !previous.contains(card.id) { view.animateArrival() }
        }
        // A clear filler at the end of the cell absorbs the column's slack height
        // so cards pack at the top (the cell itself is stretched full-height to be
        // a whole-column drop target).
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        cell.addArrangedSubview(filler)
    }

    private func face(_ card: BoardCard) -> CardFace {
        CardFace(
            card: card,
            chip: SessionCard.chipStatus(for: card) {
                RemoteHookStatus.shared.state(for: $0)
            },
            quotaBlock: lastQuotaBlocks[card.id] ?? .none,
            switchMenu: lastSwitchMenus[card.id] ?? CardSwitchMenu(accounts: [], harnesses: [])
        )
    }

    /// The card views in model-snapshot order, gathered back out of the cells —
    /// reused views for untouched columns, fresh ones for repopulated columns.
    private func orderedViews(for cards: [BoardCard]) -> [SessionCard] {
        var byID: [UUID: SessionCard] = [:]
        for cell in cells.values {
            for view in cell.arrangedSubviews.compactMap({ $0 as? SessionCard }) {
                byID[view.card.id] = view
            }
        }
        return cards.compactMap { byID[$0.id] }
    }

    func applyFontScale() {
        buildScaffold()
        render(cards: lastCards, quotaBlocks: lastQuotaBlocks, switchMenus: lastSwitchMenus)
    }

    private func countCaption(_ group: ColumnGroup, count: Int) -> String {
        switch group {
        case .needsYou: return count == 0 ? "" : "\(count)"
        case .working: return count == 0 ? "" : "\(count)"
        case .queue, .parked, .blocked: return count == 0 ? "" : "\(count)"
        case .done: return count == 0 ? "" : "\(count)"
        }
    }

    // MARK: - Keyboard navigation (arrow keys move focus, Return drills in)

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: moveFocus(-1)                       // ← ↑
        case 124, 125: moveFocus(1)                        // → ↓
        case 36, 76:                                       // return / keypad enter
            guard let card = focusedCard() else { return moveFocus(1) }
            onSelect?(card.card)
        default: super.keyDown(with: event)
        }
    }

    // ponytail: linear focus path (column by column) — a true 2D grid walk can
    // come if the board grows enough cards to need it.
    private func moveFocus(_ step: Int) {
        guard !orderedCards.isEmpty else { return }
        let current = orderedCards.firstIndex { $0.card.id == focusedCardID }
        let next = ((current ?? (step > 0 ? -1 : 0)) + step + orderedCards.count) % orderedCards.count
        setFocus(to: orderedCards[next])
    }

    private func focusedCard() -> SessionCard? {
        orderedCards.first { $0.card.id == focusedCardID }
    }

    private func setFocus(to view: SessionCard?) {
        focusedCard()?.setKeyboardFocus(false)
        focusedCardID = view?.card.id
        view?.setKeyboardFocus(true)
        // Columns scroll now, so the focused card may sit off-screen — bring it in.
        view?.scrollToVisible(view?.bounds ?? .zero)
    }

    /// After a re-render (all card views rebuilt), re-apply the ring to the view
    /// now representing the focused card; drop focus if the card is gone.
    private func restoreKeyboardFocus() {
        guard let id = focusedCardID else { return }
        if let view = orderedCards.first(where: { $0.card.id == id }) {
            view.setKeyboardFocus(true)
        } else {
            focusedCardID = nil
        }
    }

    /// Test seam: the cell backing one column group (column-move repro tests).
    func cellForTesting(_ group: ColumnGroup) -> BoardCell? { cells[group] }

    private func cardView(_ card: BoardCard) -> SessionCard {
        let view = SessionCard(
            card: card,
            quotaBlock: lastQuotaBlocks[card.id] ?? .none,
            switchMenu: lastSwitchMenus[card.id] ?? CardSwitchMenu(accounts: [], harnesses: [])
        )
        view.onSelect = { [weak self] in self?.onSelect?($0) }
        view.onRename = { [weak self] in self?.onRename?($0) }
        view.onDelete = { [weak self] in self?.onDelete?($0) }
        view.onSwitchAccount = { [weak self] in self?.onSwitchAccount?($0, $1) }
        view.onSwitchHarness = { [weak self] in self?.onSwitchHarness?($0, $1) }
        view.onDeferNeedsYou = { [weak self] in self?.onDeferNeedsYou?($0) }
        view.onPark = { [weak self] card in self?.onMove?(card.id, .parked) }
        view.onBlockExternally = { [weak self] card in self?.onMove?(card.id, .blocked) }
        return view
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.yieldWidthToWindow()
        return field
    }
}

/// Board-level chrome uses a filled surface instead of a bezel. The darker resting
/// fill keeps the control discoverable on the canvas; hover raises it without adding
/// an outline that could be confused with an attention or keyboard-focus edge.
@MainActor
final class QuietBoardButton: NSButton {
    private var hoverArea: NSTrackingArea?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryPushIn)
        isBordered = false
        controlSize = .small
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0
        themedBackground = BoardTheme.canvasSunken
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 16
        size.height = max(24, size.height + 4)
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        themedBackground = BoardTheme.cardFillRaised
    }

    override func mouseExited(with event: NSEvent) {
        themedBackground = BoardTheme.canvasSunken
    }
}

/// One board column's card container that also accepts a dragged card
/// (NSDraggingDestination). On drop it reports the card id + its representative
/// column to ``onDrop`` so the host performs the manual state change. A
/// brand-tinted ring while a drag hovers makes the drop target legible.
@MainActor
final class BoardCell: NSStackView {
    static let cardType = NSPasteboard.PasteboardType("com.sich.card")

    let column: BoardColumn
    var onDrop: ((UUID, BoardColumn) -> Void)?

    init(column: BoardColumn) {
        self.column = column
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        distribution = .fill
        registerForDraggedTypes([Self.cardType])
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.borderWidth = 1.5
        themedBorder = BoardTheme.brand
        themedBackground = BoardTheme.brand.withAlphaComponent(0.06)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearDropRing() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearDropRing()
        guard let raw = sender.draggingPasteboard.string(forType: Self.cardType),
              let id = UUID(uuidString: raw) else { return false }
        onDrop?(id, column)
        return true
    }

    private func clearDropRing() {
        layer?.borderWidth = 0
        themedBorder = nil
        themedBackground = nil
    }
}
