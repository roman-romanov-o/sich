import AppKit
import SichCore

/// The mission-control board surface (US-003), in the Mission Control v5 layout:
/// four full-height, equal-width columns — QUEUE / WORKING / NEEDS YOU / DONE —
/// instead of raw state columns × flow swimlanes. Flow is card
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

    /// The v5 column groups, left→right.
    enum ColumnGroup: CaseIterable {
        case queue, working, needsYou, done

        /// Every `CardState` lands in exactly one group — total, so no card can
        /// silently vanish from the board (the `.unknown` regression).
        static func group(for state: CardState) -> ColumnGroup {
            switch state {
            case .waitingForInput, .blocked: return .needsYou
            case .running, .runningTests: return .working
            case .idle, .unknown: return .queue
            case .done: return .done
            }
        }

        var title: String {
            switch self {
            case .needsYou: return "NEEDS YOU"
            case .working: return "WORKING"
            case .queue: return "QUEUE"
            case .done: return "DONE"
            }
        }

        /// The state a manual drop into this group sets, expressed as the
        /// representative `BoardColumn` (the host's `onMove` contract).
        var dropColumn: BoardColumn {
            switch self {
            case .needsYou: return .waitingForInput
            case .working: return .running
            case .queue: return .idle
            case .done: return .done
            }
        }

        /// The pulsing status dot next to the header — only the live columns get one.
        @MainActor var dotColor: NSColor? {
            switch self {
            case .needsYou: return BoardTheme.attention
            case .working: return BoardTheme.stateColor(.running)
            case .queue, .done: return nil
            }
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
    private var lastCards: [BoardCard] = []
    override init(frame frameRect: NSRect) {
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
        var previous: NSView?
        // Four equal columns: QUEUE → WORKING → NEEDS YOU → DONE. The unfinished
        // backlog UI stays out of this live-work surface.
        let columns = groups.map { makeColumn($0) }
        for column in columns {
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: topAnchor),
                column.bottomAnchor.constraint(equalTo: bottomAnchor),
                column.leadingAnchor.constraint(
                    equalTo: previous?.trailingAnchor ?? leadingAnchor),
            ])
            if let previous {
                column.widthAnchor.constraint(equalTo: previous.widthAnchor).isActive = true
            }
            previous = column
        }
        previous?.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
    }

    private func makeColumn(_ group: ColumnGroup) -> NSView {
        let column = NSView()
        column.wantsLayer = true
        if group == .needsYou {
            column.themedBackground = BoardTheme.needsYouColumn
        }
        if group != .done { addRightHairline(to: column) }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: column.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])

        let header = columnHeader(group)
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

    /// Centered lane signage: dot + TITLE + count travel as one cluster (a
    /// centered title with the count still glued to the right edge would read
    /// as two disconnected floats). Equal-width spacers do the centering.
    private func columnHeader(_ group: ColumnGroup) -> NSView {
        let row = NSStackView()
        row.spacing = 8
        let lead = NSView()
        let trail = NSView()
        row.addArrangedSubview(lead)
        if let dotColor = group.dotColor { row.addArrangedSubview(pulsingDot(dotColor)) }
        let titleColor: NSColor =
            group == .needsYou ? BoardTheme.attention : BoardTheme.textMuted
        let title = label(group.title, font: BoardTheme.columnTitle, color: titleColor)
        title.attributedStringValue = BoardTheme.caps(group.title, color: titleColor)
        row.addArrangedSubview(title)
        let count = label("", font: BoardTheme.mono, color: BoardTheme.textFaint)
        countLabels[group] = count
        row.addArrangedSubview(count)
        if group == .queue { row.addArrangedSubview(createButton()) }
        row.addArrangedSubview(trail)
        lead.widthAnchor.constraint(equalTo: trail.widthAnchor).isActive = true
        return row
    }

    private func pulsingDot(_ color: NSColor) -> NSView {
        let dot = NSView()
        dot.themedBackground = color
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
        return dot
    }

    /// A large, familiar add symbol beside QUEUE: new work enters the board here.
    /// The tooltip and accessibility label preserve the text cue without spending
    /// a second row on visible helper copy.
    private func createButton() -> NSButton {
        let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let image = NSImage(
            systemSymbolName: "plus.circle.fill",
            accessibilityDescription: "Add task"
        )?.withSymbolConfiguration(configuration)
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(createTapped))
        button.identifier = NSUserInterfaceItemIdentifier("add-task")
        button.title = ""
        button.toolTip = "Add task"
        button.setAccessibilityLabel("Add task")
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.contentTintColor = BoardTheme.brand
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
        return button
    }

    @objc private func createTapped() { onCreate?() }

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

    /// Project a card snapshot onto the columns. Clearing + repopulating each cell
    /// is the live-column-move mechanism (US-003 AC#3).
    func render(cards: [BoardCard]) {
        lastCards = cards
        for cell in cells.values {
            cell.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        var counts: [ColumnGroup: Int] = [:]
        var placed: [(group: Int, order: Int, view: SessionCard)] = []
        for (order, card) in cards.enumerated() {
            let group = ColumnGroup.group(for: card.state)
            counts[group, default: 0] += 1
            guard let cell = cells[group] else { continue }
            let view = cardView(card)
            cell.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            placed.append((groups.firstIndex(of: group) ?? 0, order, view))
        }
        // A clear filler at the end of each cell absorbs the column's slack height
        // so cards pack at the top (the cell itself is stretched full-height to be
        // a whole-column drop target).
        for cell in cells.values {
            let filler = NSView()
            filler.setContentHuggingPriority(.init(1), for: .vertical)
            cell.addArrangedSubview(filler)
        }
        // Keyboard order follows the model snapshot order. Visual placement still
        // happens by column above, but arrow-key traversal stays stable across live
        // state moves so focus does not jump when a card changes columns.
        orderedCards = placed.sorted { $0.order < $1.order }.map(\.view)
        restoreKeyboardFocus()
        for group in groups {
            countLabels[group]?.stringValue = countCaption(group, count: counts[group] ?? 0)
        }
    }

    func applyFontScale() {
        buildScaffold()
        render(cards: lastCards)
    }

    private func countCaption(_ group: ColumnGroup, count: Int) -> String {
        switch group {
        case .needsYou: return count == 0 ? "" : "\(count)"
        case .working: return count == 0 ? "" : "\(count)"
        case .queue: return count == 0 ? "" : "\(count)"
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
        let view = SessionCard(card: card)
        view.onSelect = { [weak self] in self?.onSelect?($0) }
        view.onRename = { [weak self] in self?.onRename?($0) }
        view.onDelete = { [weak self] in self?.onDelete?($0) }
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
