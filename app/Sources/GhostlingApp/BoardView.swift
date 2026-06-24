import AppKit
import GhostlingCore

/// The mission-control board surface (US-003): state columns × two-flow
/// swimlanes, rendered against the HELM POC (`research/UI_POC.html`). Columns are
/// the lifecycle states (with `waiting`+`blocked` merged under one `⚠ attention`
/// header per the POC); rows split Flow-A (saha) / Flow-B (interactive).
///
/// It is a pure projection of a `[BoardCard]` snapshot: ``render(cards:)`` lays
/// the cards out by `(column, flow)`. Live column moves (US-003 AC#3) come from
/// the host re-calling `render` as state changes. Card clicks bubble up via
/// ``onSelect`` for drill-in (US-002).
@MainActor
final class BoardView: NSView {
    /// Drill-in: a card was clicked (US-002 AC#1). The host focuses its terminal.
    var onSelect: ((BoardCard) -> Void)?

    /// The columns drawn, left→right. `idle` is omitted from the rendered board to
    /// match the POC's `backlog · ready · running · ⚠ waiting·blocked · review ·
    /// done`-style strip while keeping the underlying state enum complete. We keep
    /// the six real columns the stories name, merging waiting+blocked visually.
    private let columns: [BoardColumn] = [
        .idle, .running, .waitingForInput, .runningTests, .done,
    ]
    private let flows: [CardFlow] = [.a, .b]

    private let headerStack = NSStackView()
    private let gridStack = NSStackView()
    /// Reusable per-(column,flow) cell containers, keyed for fast re-render.
    private var cells: [CellKey: NSStackView] = [:]

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
        headerStack.spacing = ColumnLayout.gap
        headerStack.addArrangedSubview(spacer(width: ColumnLayout.laneLabel))
        for column in columns { headerStack.addArrangedSubview(columnHeader(column)) }
    }

    private func configureGrid() {
        gridStack.orientation = .vertical
        gridStack.spacing = 12
        for flow in flows { gridStack.addArrangedSubview(swimlaneRow(flow)) }
    }

    // MARK: - Header + swimlane construction

    private func columnHeader(_ column: BoardColumn) -> NSView {
        let amber = column.isAttention
        let title = label(
            columnTitle(column),
            font: BoardTheme.monoBold,
            color: amber ? BoardTheme.attention : BoardTheme.textMuted
        )
        let box = NSView()
        box.wantsLayer = true
        title.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(title)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: ColumnLayout.column),
            title.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            title.topAnchor.constraint(equalTo: box.topAnchor),
            title.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
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
            let cell = makeCell()
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
        let big = label(flow.rawValue, font: BoardTheme.monoBold, color: BoardTheme.textPrimary)
        let sub = label(
            flow == .a ? "saha · autonomous" : "interactive · human-launched",
            font: BoardTheme.monoSmall, color: BoardTheme.textFaint
        )
        stack.addArrangedSubview(big)
        stack.addArrangedSubview(sub)
        stack.widthAnchor.constraint(equalToConstant: ColumnLayout.laneLabel).isActive = true
        return stack
    }

    private func makeCell() -> NSStackView {
        let cell = NSStackView()
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 8
        cell.widthAnchor.constraint(equalToConstant: ColumnLayout.column).isActive = true
        return cell
    }

    // MARK: - Render (called on every state change → live column moves)

    /// Project a card snapshot onto the grid. Clearing + repopulating each cell is
    /// the live-column-move mechanism (US-003 AC#3): a re-render after a state
    /// change lands the card in its new column.
    func render(cards: [BoardCard]) {
        for cell in cells.values {
            cell.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        for card in cards {
            let key = CellKey(column: renderColumn(for: card.state), flow: card.flow)
            guard let cell = cells[key] else { continue }
            cell.addArrangedSubview(cardView(card))
        }
    }

    /// Map a state to the column it renders in. `blocked` merges into the
    /// `waitingForInput` (attention) column per the POC; `unknown` parks in
    /// `running`'s neighbor by falling back to `runningTests` is wrong — instead
    /// unknown cards stay out of the five rendered columns (they are an explicit
    /// edge handled by the detector layer, not a happy-path board column).
    private func renderColumn(for state: CardState) -> BoardColumn {
        state == .blocked ? .waitingForInput : BoardColumn(state: state)
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

    private func spacer(width: CGFloat) -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
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

/// Fixed geometry for the board grid — column width, lane-label gutter, gaps.
private enum ColumnLayout {
    static let column: CGFloat = 180
    static let laneLabel: CGFloat = 120
    static let gap: CGFloat = 14
}

/// Key for a single board cell — one (column, flow) intersection.
private struct CellKey: Hashable {
    let column: BoardColumn
    let flow: CardFlow
}
