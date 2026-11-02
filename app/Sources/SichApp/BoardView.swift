import AppKit
import SichCore

/// The mission-control board surface (US-003): six lanes, left→right —
/// BACKLOG / QUEUE / WORKING / NEEDS YOU / BLOCKED / DONE. DONE can be folded
/// into a narrow rail (``DoneRail``) so a laptop-width board spends its width on
/// the live lanes; the fold persists across launches. Flow is card metadata (the
/// harness mark on the card footer), not a lane.
///
/// One signal: NEEDS YOU is the only lane with a hue of its own. Beyond it the
/// board lights exactly one lane — the *focus* — where the operator should look
/// next (``focus(for:)``). Cards fall under their project inside a lane, so the
/// repo is read once per cluster and the card face spends its rows on the title.
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

    /// The column groups, left→right.
    enum ColumnGroup: CaseIterable {
        case parked, queue, working, needsYou, blocked, done

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
            case .parked: return "BACKLOG"
            case .queue: return "QUEUE"
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
    }

    /// Where the operator's attention should go next: NEEDS YOU whenever it holds
    /// a card; otherwise — everything is working or at rest, nothing will ask for
    /// you in the next minutes — back to QUEUE to pull or create the next task;
    /// with an empty QUEUE, to BACKLOG to promote one. With nothing anywhere the
    /// + beside QUEUE is the only move left.
    static func focus(for counts: [ColumnGroup: Int]) -> ColumnGroup {
        if counts[.needsYou, default: 0] > 0 { return .needsYou }
        if counts[.queue, default: 0] > 0 { return .queue }
        if counts[.parked, default: 0] > 0 { return .parked }
        return .queue
    }

    /// Where the DONE fold choice lives; tests hand in a throwaway suite.
    private let defaults: UserDefaults
    private static let doneCollapsedKey = "board.doneCollapsed"
    /// Width of the DONE column while collapsed — just the header chrome, stacked.
    static let doneRailWidth: CGFloat = 44

    /// DONE folded into a narrow rail so the live columns get its width.
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
    /// Cards in render order (BACKLOG column top→bottom, then QUEUE, …) — the
    /// linear path arrow keys walk. Rebuilt on every render; focus re-found by id.
    private var orderedCards: [SessionCard] = []
    private var focusedCardID: UUID?
    /// Per-column count captions, updated on every render.
    private var countLabels: [ColumnGroup: NSTextField] = [:]
    /// What a lane's tone touches: its column surface and caps title.
    private var laneViews: [ColumnGroup: (column: NSView, title: NSTextField)] = [:]
    /// The + beside QUEUE — brand blue only while QUEUE is the lit lane.
    private weak var createControl: NSButton?
    /// The lit lane after the last render; `nil` before the first one, so launch
    /// does not animate and a lane only breathes when the focus actually moves.
    private var lastFocus: ColumnGroup?
    private var lastCards: [BoardCard] = []
    private var lastQuotaBlocks: [UUID: CardQuotaBlock] = [:]
    private var lastSwitchMenus: [UUID: CardSwitchMenu] = [:]
    /// Cards a running pomodoro / break is holding — drawn dimmed.
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

    // MARK: - Scaffold (built once): equal columns filling the surface

    /// Lanes keep a fixed, equal width (DONE at ``narrowDoneRatio`` in a portrait
    /// window), so the only thing that ever moves on the board is a card.
    private func buildScaffold() {
        subviews.forEach { $0.removeFromSuperview() }
        constraints.forEach { $0.isActive = false }
        cells = [:]
        countLabels = [:]
        laneViews = [:]
        columnFaces = [:]
        lastFocus = nil
        var previous: NSView?
        var anchor: NSView?
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
            } else if let anchor {
                let ratio = group == .done && isDoneNarrow ? Self.narrowDoneRatio : 1
                column.widthAnchor.constraint(equalTo: anchor.widthAnchor, multiplier: ratio).isActive = true
            } else {
                anchor = column
            }
            previous = column
        }
        previous?.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
    }

    private func makeColumn(_ group: ColumnGroup) -> NSView {
        let column = NSView()
        column.wantsLayer = true
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

    /// Centered lane signage: TITLE + count travel as one cluster (a centered
    /// title with the count still glued to the right edge would read as two
    /// disconnected floats). Equal-width spacers do the centering.
    private func columnHeader(_ group: ColumnGroup, column: NSView) -> NSView {
        let row = NSStackView()
        row.spacing = 8
        // Six columns × the row's inter-item spacing would otherwise set a hard
        // window-width floor; clip the header instead of refusing a shrink.
        row.setClippingResistancePriority(.init(490), for: .horizontal)
        let lead = NSView()
        let trail = NSView()
        row.addArrangedSubview(lead)
        let title = label(group.title, font: BoardTheme.columnTitle, color: BoardTheme.textMuted)
        row.addArrangedSubview(title)
        laneViews[group] = (column, title)
        let count = label("0", font: BoardTheme.laneCount, color: BoardTheme.textMuted)
        countLabels[group] = count
        row.addArrangedSubview(count)
        applyLaneTone(group, count: 0, focused: false)
        if group == .queue {
            let create = createButton()
            createControl = create
            row.addArrangedSubview(create)
        }
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

    /// A large, familiar add symbol beside QUEUE: new work enters the board here.
    /// Quiet by default; it takes the brand blue only while QUEUE is the lit lane.
    /// The tooltip and accessibility label preserve the text cue without spending
    /// a second row on visible helper copy.
    private func createButton() -> NSButton {
        BoardSymbolButton.make(
            symbol: "plus.circle.fill", pointSize: 17, tint: BoardTheme.textFaint,
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
        switchMenus: [UUID: CardSwitchMenu] = [:],
        held: Set<UUID> = []
    ) {
        lastCards = cards
        lastQuotaBlocks = quotaBlocks
        lastSwitchMenus = switchMenus
        var byGroup: [ColumnGroup: [BoardCard]] = [:]
        for card in cards {
            byGroup[ColumnGroup.group(for: card.state), default: []].append(card)
        }
        let counts = byGroup.mapValues(\.count)
        // A held card (NEEDS YOU raised mid-pomodoro) looks like any other card —
        // it only waits quietly: no lane focus, no alert, no standup until the break.
        var focusCounts = counts
        focusCounts[.needsYou] = (byGroup[.needsYou] ?? []).filter { !held.contains($0.id) }.count
        let focus = Self.focus(for: focusCounts)
        for group in groups {
            renderColumn(group, cards: byGroup[group] ?? [])
            let count = counts[group] ?? 0
            countLabels[group]?.stringValue = "\(count)"
            applyLaneTone(group, count: count, focused: group == focus)
        }
        // Focus landing on an EMPTY queue is an invitation to create: the + breathes.
        if focus == .queue, counts[.queue, default: 0] == 0, lastFocus != nil, lastFocus != .queue {
            breatheCreateControl()
        }
        lastFocus = focus
        // Keyboard order follows the model snapshot order. Visual placement still
        // happens by column above, but arrow-key traversal stays stable across live
        // state moves so focus does not jump when a card changes columns.
        orderedCards = orderedViews(for: cards)
        restoreKeyboardFocus()
    }

    /// The lit lane. NEEDS YOU keeps its red while it holds a card (US-005 AC#3:
    /// an empty NEEDS YOU is quiet, no false alarm); any other lit lane lifts a
    /// shade toward the brand blue with its title in the focus ink. The handoff is
    /// a 300ms crossfade of the surface — system-driven and frequent, so no movement.
    private func applyLaneTone(_ group: ColumnGroup, count: Int, focused: Bool) {
        guard let lane = laneViews[group] else { return }
        let needsLit = group == .needsYou && count > 0
        let background: NSColor? = needsLit ? BoardTheme.needsYouColumn
            : focused ? BoardTheme.focusColumn : nil
        let ink: NSColor = needsLit ? BoardTheme.needs
            : focused ? BoardTheme.focusInk : BoardTheme.textMuted
        // Only the colour changes here; the caps keep the font the header was built
        // with, so a re-tone never resizes one title out of step with its count.
        let caps = NSMutableAttributedString(
            attributedString: BoardTheme.caps(group.title, color: ink))
        if let font = lane.title.font {
            caps.addAttribute(.font, value: font, range: NSRange(location: 0, length: caps.length))
        }
        lane.title.attributedStringValue = caps
        countLabels[group]?.textColor = ink
        if group == .queue {
            createControl?.contentTintColor = focused ? BoardTheme.brand : BoardTheme.textFaint
        }
        crossfade(lane.column, to: background)
    }

    /// Set a lane's surface, fading from whatever it shows now when motion is on.
    private func crossfade(_ column: NSView, to color: NSColor?) {
        guard column.themedBackground != color else { return }
        guard let layer = column.layer, lastFocus != nil, Self.motionAllowed else {
            column.themedBackground = color
            return
        }
        let from = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        column.themedBackground = color
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = from ?? NSColor.clear.cgColor
        fade.toValue = layer.backgroundColor ?? NSColor.clear.cgColor
        fade.duration = 0.3
        fade.timingFunction = Self.easeOut
        layer.add(fade, forKey: "lane-tone")
    }

    /// The + swells twice — the one invitation the board makes.
    private func breatheCreateControl() {
        guard Self.motionAllowed, let button = createControl, let layer = button.layer else { return }
        let cx = button.bounds.midX, cy = button.bounds.midY
        func scaled(_ s: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(cx, cy, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -cx, -cy, 0)
        }
        let breathe = CAKeyframeAnimation(keyPath: "transform")
        breathe.values = [scaled(1), scaled(1.18), scaled(1)]
        breathe.keyTimes = [0, 0.4, 1]
        breathe.duration = 1.1
        breathe.repeatCount = 2
        breathe.timingFunction = Self.easeOut
        layer.add(breathe, forKey: "breathe")
    }

    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    static var motionAllowed: Bool {
        motionOverrideForTesting ?? !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    /// Test seam: pin the Reduce Motion reading so a test's outcome does not depend
    /// on the machine's accessibility settings.
    static var motionOverrideForTesting: Bool?

    private func renderColumn(_ group: ColumnGroup, cards: [BoardCard]) {
        guard let cell = cells[group] else { return }
        let faces = cards.map(face)
        guard columnFaces[group] != faces else { return }
        // Cards new to this lane since its last render have just moved here (or were
        // just created). A freshly built scaffold has no "last render" — launch and
        // zoom rebuilds stay still.
        let previous = columnFaces[group].map { Set($0.map(\.card.id)) }
        columnFaces[group] = faces
        // A card leaving this lane keeps its old view behind as a ghost that closes
        // up where it stood, so the cards below slide together by layout.
        let staying = Set(cards.map(\.id))
        let departed: [(SessionCard, Int)] = previous == nil ? [] :
            cell.arrangedSubviews.enumerated().compactMap { index, view in
                guard let card = view as? SessionCard, !card.isGhost,
                      !staying.contains(card.card.id) else { return nil }
                return (card, index)
            }
        cell.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var arrivals: [SessionCard] = []
        for (label, members) in Self.projectGroups(cards) {
            let header = ProjectHeader(label: label, count: members.count)
            cell.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            for (index, card) in members.enumerated() {
                let view = cardView(card)
                view.sheenPhase = index
                cell.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
                if let previous, !previous.contains(card.id) { arrivals.append(view) }
            }
            if let last = cell.arrangedSubviews.last { cell.setCustomSpacing(14, after: last) }
        }
        // A clear filler at the end of the cell absorbs the column's slack height
        // so cards pack at the top (the cell itself is stretched full-height to be
        // a whole-column drop target).
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        cell.addArrangedSubview(filler)
        for view in arrivals {
            view.animateArrival()
            expandIn(view, in: cell)
        }
        for (ghost, index) in departed { collapseOut(ghost, in: cell, at: index) }
    }

    /// Cards within a lane fall under their project, in the order the lane first
    /// met each project.
    static func projectGroups(_ cards: [BoardCard]) -> [(label: String, cards: [BoardCard])] {
        var order: [String] = []
        var members: [String: [BoardCard]] = [:]
        for card in cards {
            let key = BoardTheme.projectLabel(for: card)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(card)
        }
        return order.map { ($0, members[$0] ?? []) }
    }

    /// The arriving card grows from a closed line to its full height while it
    /// fades in — the cards below are pushed down by layout, so no sibling needs an
    /// animation of its own. Reduce Motion keeps the fade and skips the growth.
    private func expandIn(_ view: SessionCard, in cell: BoardCell) {
        guard Self.motionAllowed else { return }
        cell.layoutSubtreeIfNeeded()
        let height = view.frame.height
        guard height > 0 else { return }
        let closed = view.heightAnchor.constraint(equalToConstant: 0)
        view.layer?.masksToBounds = true
        closed.isActive = true
        cell.layoutSubtreeIfNeeded()
        // The async form keeps the clean-up on the main actor: the completion-handler
        // form hands AppKit a @Sendable closure that may not touch views or constraints.
        Task { @MainActor in
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = Self.easeOut
                context.allowsImplicitAnimation = true
                closed.animator().constant = height
                cell.layoutSubtreeIfNeeded()
            }
            closed.isActive = false
            view.layer?.masksToBounds = false
        }
    }

    /// A ghost of the departed card is put back where it was and closes up, so the
    /// source lane's cards slide together by layout rather than by transform.
    private func collapseOut(_ ghost: SessionCard, in cell: BoardCell, at index: Int) {
        guard Self.motionAllowed else { return }
        ghost.becomeGhost()
        let slot = min(index, max(0, cell.arrangedSubviews.count - 1))   // before the filler
        cell.insertArrangedSubview(ghost, at: slot)
        ghost.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
        cell.layoutSubtreeIfNeeded()
        let open = ghost.heightAnchor.constraint(equalToConstant: ghost.frame.height)
        open.isActive = true
        ghost.layer?.masksToBounds = true
        Task { @MainActor in
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
                context.allowsImplicitAnimation = true
                open.animator().constant = 0
                ghost.animator().alphaValue = 0
                cell.layoutSubtreeIfNeeded()
            }
            ghost.removeFromSuperview()
        }
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
            for view in cell.arrangedSubviews.compactMap({ $0 as? SessionCard }) where !view.isGhost {
                byID[view.card.id] = view
            }
        }
        return cards.compactMap { byID[$0.id] }
    }

    func applyFontScale() {
        buildScaffold()
        render(cards: lastCards, quotaBlocks: lastQuotaBlocks, switchMenus: lastSwitchMenus)
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

/// The header over one project's cards inside a lane: a neutral dot, the repo
/// name (mono, truncated in the middle — names differ at the end), and the
/// cluster's size when it is more than one card.
@MainActor
final class ProjectHeader: NSView {
    init(label: String, count: Int) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("project-header")
        let row = NSStackView()
        row.spacing = 6
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 14),
        ])
        let dot = NSView()
        dot.themedBackground = BoardTheme.cardStrokeStrong
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        row.addArrangedSubview(dot)
        let name = NSTextField(labelWithString: label)
        name.font = BoardTheme.projectHeader
        name.textColor = BoardTheme.textFaint
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = label
        name.yieldWidthToWindow(.defaultLow)
        row.addArrangedSubview(name)
        row.addArrangedSubview(NSView())   // flexible spacer
        if count > 1 {
            let size = NSTextField(labelWithString: "\(count)")
            size.font = BoardTheme.numericSmall
            size.textColor = BoardTheme.textDim
            row.addArrangedSubview(size)
        }
    }

    required init?(coder: NSCoder) { nil }
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
        // Cards of one project sit 8pt apart; the next project starts 14pt below.
        spacing = 8
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
