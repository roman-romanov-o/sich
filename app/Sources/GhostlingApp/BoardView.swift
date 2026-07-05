import AppKit
import GhostlingCore

/// The mission-control board surface (US-003): state columns × two-flow
/// swimlanes, in the Deep Slate palette. Columns are the lifecycle states (with
/// `waiting`+`blocked` merged under one `⚠ attention` header); rows split Flow-A
/// (saha) / Flow-B (interactive).
///
/// It is a projection of a `[BoardCard]` snapshot: ``render(cards:)`` lays the
/// cards out by `(column, flow)`. Live column moves come from the host re-calling
/// `render`. Three callbacks bubble up: ``onSelect`` (drill-in, US-002),
/// ``onCreate`` (the "+ new session" affordance), and ``onMove`` (a card dragged
/// to a new column → manual state change).
@MainActor
final class BoardView: NSView {
    /// Drill-in: a card was clicked (US-002 AC#1). The host focuses its terminal.
    var onSelect: ((BoardCard) -> Void)?
    /// The "+ new session" affordance was tapped — the host launches a live card.
    var onCreate: (() -> Void)?
    /// A card was dropped on a column — the host moves it (manual state change).
    var onMove: ((UUID, BoardColumn) -> Void)?

    private let columns: [BoardColumn] = [
        .idle, .running, .waitingForInput, .runningTests, .done,
    ]
    private let flows: [CardFlow] = [.a, .b]

    private let headerStack = NSStackView()
    private let gridStack = NSStackView()
    private var cells: [CellKey: BoardCell] = [:]
    /// Cards in render order (Flow-A row left→right, then Flow-B) — the linear
    /// path arrow keys walk. Rebuilt on every render; focus is re-found by id.
    private var orderedCards: [SessionCard] = []
    private var focusedCardID: UUID?
    /// Per-column count badges, updated on every render (live work-in-progress).
    private var countLabels: [BoardColumn: NSTextField] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = BoardTheme.canvas.cgColor
        buildScaffold()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Scaffold (built once)

    private func buildScaffold() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        configureHeader()
        configureGrid()
        root.addArrangedSubview(headerStack)
        root.addArrangedSubview(gridStack)
    }

    private func configureHeader() {
        headerStack.orientation = .horizontal
        headerStack.alignment = .bottom
        headerStack.spacing = ColumnLayout.gap
        headerStack.addArrangedSubview(createButton())
        for column in columns { headerStack.addArrangedSubview(columnHeader(column)) }
    }

    private func configureGrid() {
        gridStack.orientation = .vertical
        gridStack.spacing = 12
        for flow in flows { gridStack.addArrangedSubview(swimlaneRow(flow)) }
    }

    // MARK: - Header + swimlane construction

    /// The "+ new session" affordance, sized to the lane-label gutter so the
    /// columns still line up under their headers.
    private func createButton() -> NSView {
        let button = NSButton(title: "+ new session", target: self, action: #selector(createTapped))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.contentTintColor = BoardTheme.brand
        button.font = BoardTheme.monoBold
        button.widthAnchor.constraint(equalToConstant: ColumnLayout.laneLabel).isActive = true
        return button
    }

    @objc private func createTapped() { onCreate?() }

    private func columnHeader(_ column: BoardColumn) -> NSView {
        let amber = column.isAttention
        let title = label(
            columnTitle(column),
            font: BoardTheme.monoBold,
            color: amber ? BoardTheme.attention : BoardTheme.textMuted
        )
        let count = countBadge()
        countLabels[column] = count
        let box = NSView()
        box.wantsLayer = true
        let row = NSStackView(views: [title, count])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: ColumnLayout.column),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            row.topAnchor.constraint(equalTo: box.topAnchor),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])
        addUnderline(to: box, amber: amber)
        return box
    }

    private func swimlaneRow(_ flow: CardFlow) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = ColumnLayout.gap
        row.addArrangedSubview(laneLabel(flow))
        for column in columns {
            let cell = makeCell(column: column)
            cells[CellKey(column: column, flow: flow)] = cell
            row.addArrangedSubview(cell)
        }
        return row
    }

    private func laneLabel(_ flow: CardFlow) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        let big = label(flow.rawValue, font: BoardTheme.monoBold, color: BoardTheme.flowColor(flow))
        let sub = label(
            flow == .a ? "saha · autonomous" : "interactive · human-launched",
            font: BoardTheme.monoSmall, color: BoardTheme.textFaint
        )
        // "interactive · human-launched" is wider than the gutter at any sane
        // width, so wrap it to two lines instead of truncating to "interactive · hu…".
        sub.maximumNumberOfLines = 2
        sub.lineBreakMode = .byWordWrapping
        sub.preferredMaxLayoutWidth = ColumnLayout.laneLabel
        stack.addArrangedSubview(big)
        stack.addArrangedSubview(sub)
        stack.widthAnchor.constraint(equalToConstant: ColumnLayout.laneLabel).isActive = true
        return stack
    }

    private func makeCell(column: BoardColumn) -> BoardCell {
        let cell = BoardCell(column: column)
        cell.onDrop = { [weak self] id, col in self?.onMove?(id, col) }
        cell.widthAnchor.constraint(equalToConstant: ColumnLayout.column).isActive = true
        cell.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        return cell
    }

    // MARK: - Render (called on every state change → live column moves)

    /// Project a card snapshot onto the grid. Clearing + repopulating each cell is
    /// the live-column-move mechanism (US-003 AC#3).
    func render(cards: [BoardCard]) {
        for cell in cells.values {
            cell.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        var counts: [BoardColumn: Int] = [:]
        var placed: [(flow: Int, col: Int, view: SessionCard)] = []
        for card in cards {
            let column = renderColumn(for: card.state)
            counts[column, default: 0] += 1
            guard let cell = cells[CellKey(column: column, flow: card.flow)] else { continue }
            let view = cardView(card)
            cell.addArrangedSubview(view)
            placed.append((flows.firstIndex(of: card.flow) ?? 0,
                           columns.firstIndex(of: column) ?? 0, view))
        }
        // Visual order: Flow-A lane left→right, then Flow-B — the arrow-key path.
        orderedCards = placed.sorted { ($0.flow, $0.col) < ($1.flow, $1.col) }.map(\.view)
        restoreKeyboardFocus()
        for (column, badge) in countLabels {
            let n = counts[column] ?? 0
            badge.stringValue = n == 0 ? "" : "\(n)"
        }
        // A faint placeholder in any empty (column, flow) cell so a blank lane reads
        // as "nothing here" rather than a broken/missing column.
        for cell in cells.values where cell.arrangedSubviews.isEmpty {
            cell.addArrangedSubview(emptyPlaceholder())
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

    // ponytail: linear focus path (flow lane, then column) — a true 2D grid walk
    // (↑↓ jump between lanes) can come if the board grows enough cards to need it.
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

    private func emptyPlaceholder() -> NSView {
        label("·", font: BoardTheme.mono, color: BoardTheme.textFaint)
    }

    private func renderColumn(for state: CardState) -> BoardColumn {
        switch state {
        case .blocked: return .waitingForInput   // merged under the ⚠ attention header
        // ponytail: a session that went silent (agent quit with no Stop/SessionEnd
        // hook, then the 30s stale sweep) decays to .unknown. Land it back in `idle`
        // so the card stays VISIBLE — mapping to a `.unknown` column, which the 5-col
        // grid has no cell for, made `render` silently `continue` past it and the card
        // vanished from the board ("task just disappeared"). No dedicated unknown
        // column: a 6th column clips the fixed layout — add one (with horizontal
        // scroll) if "went-silent" ever needs its own lane.
        case .unknown: return .idle
        default: return BoardColumn(state: state)
        }
    }

    private func cardView(_ card: BoardCard) -> SessionCard {
        let view = SessionCard(card: card)
        view.onSelect = { [weak self] in self?.onSelect?($0) }
        return view
    }

    // MARK: - Small builders

    private func columnTitle(_ column: BoardColumn) -> String {
        column == .waitingForInput ? "⚠ waiting · blocked" : column.rawValue
    }

    private func countBadge() -> NSTextField {
        label("", font: BoardTheme.monoSmall, color: BoardTheme.textFaint)
    }

    private func addUnderline(to box: NSView, amber: Bool) {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = (amber ? BoardTheme.attention : BoardTheme.hairline).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        return field
    }
}

/// One board cell — a `(column, flow)` intersection that also accepts a dragged
/// card (NSDraggingDestination). On drop it reports the card id + its own column
/// to ``onDrop`` so the host performs the manual state change. A brand-tinted
/// ring while a drag hovers makes the drop target legible.
@MainActor
final class BoardCell: NSStackView {
    static let cardType = NSPasteboard.PasteboardType("com.ghostling.card")

    let column: BoardColumn
    var onDrop: ((UUID, BoardColumn) -> Void)?

    init(column: BoardColumn) {
        self.column = column
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        wantsLayer = true
        layer?.cornerRadius = 8
        registerForDraggedTypes([Self.cardType])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.borderWidth = 1.5
        layer?.borderColor = BoardTheme.brand.cgColor
        layer?.backgroundColor = BoardTheme.brand.withAlphaComponent(0.06).cgColor
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
        layer?.backgroundColor = nil
    }
}

/// Fixed geometry for the board grid — column width, lane-label gutter, gaps.
/// Sized so all 5 columns + the lane gutter fit the default 1400×860 window
/// (board frame ≈1016pt; content 116 + 5×170 + 5×10 = 1006pt). ponytail: fixed
/// widths with a known ceiling — if the window is dragged narrower than ~1360
/// the "done" column clips with no scroll signal; upgrade to a horizontal
/// NSScrollView when multi-monitor/narrow-window support actually matters.
private enum ColumnLayout {
    static let column: CGFloat = 170
    static let laneLabel: CGFloat = 116
    static let gap: CGFloat = 10
}

/// Key for a single board cell — one (column, flow) intersection.
private struct CellKey: Hashable {
    let column: BoardColumn
    let flow: CardFlow
}
