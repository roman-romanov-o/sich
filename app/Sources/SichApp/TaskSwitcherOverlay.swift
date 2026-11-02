import AppKit
import SichCore

/// The Ctrl+Tab switcher overlay (VS Code style): a centred panel listing drillable
/// tasks — NEEDS YOU cards first, most-recently-focused first within each tier — with
/// one chosen row. The shell steps the highlight on held-⌃ presses and commits on
/// ⌃ release; this view is pure presentation plus the two pure ordering helpers the
/// shell (and tests) call. Custom-drawn and layer-backed like `SessionCard` — stock
/// control chrome doesn't composite reliably on this hand-painted UI.
@MainActor
final class TaskSwitcherOverlay: NSView {
    private let panel = NSView()
    private let rows = NSStackView()

    init() {
        super.init(frame: .zero)
        isHidden = true
        // Choosing is modal while ⌃ is held: dim the board so the list is the one
        // thing to read, without hiding where you are.
        wantsLayer = true
        themedBackground = BoardTheme.switcherScrim
        buildPanel()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Ordering (pure)

    /// Switcher order: NEEDS YOU (waiting/blocked) cards first, then the rest — each
    /// tier ranked most-recently-focused first (`mru` is focus history, front =
    /// latest); never-focused cards keep their board order after the ranked ones.
    static func ordered(cards: [BoardCard], mru: [UUID]) -> [BoardCard] {
        let ranked = cards.enumerated().sorted { lhs, rhs in
            let lhsRank = mru.firstIndex(of: lhs.element.id) ?? Int.max
            let rhsRank = mru.firstIndex(of: rhs.element.id) ?? Int.max
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }.map(\.element)
        return ranked.filter(\.state.needsAttention) + ranked.filter { !$0.state.needsAttention }
    }

    /// Where the highlight starts: the first (or, reversed, last) entry that is not
    /// the currently focused card — so a quick tap always means "go somewhere else".
    static func initialHighlight(in cards: [BoardCard], current: UUID?, reverse: Bool) -> Int {
        let other = reverse
            ? cards.lastIndex { $0.id != current }
            : cards.firstIndex { $0.id != current }
        return other ?? 0
    }

    // MARK: - Rendering

    /// Repaint the list from the shell's frozen snapshot. Rebuilding the rows outright
    /// is fine at this scale (a dozen cards) and keeps the view stateless.
    func render(cards: [BoardCard], highlight: Int) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var previousNeedsYou: Bool?
        for (index, card) in cards.enumerated() {
            let needs = card.state.needsAttention
            if previousNeedsYou == true, !needs { addSeparator() }
            previousNeedsYou = needs
            addFullWidth(row(for: card, highlighted: index == highlight))
        }
        let hint = label("⇥ next   ⇧⇥ previous   release ⌃ to switch   esc cancels",
                         font: .systemFont(ofSize: 12), color: BoardTheme.textDim)
        hint.alignment = .center
        rows.setCustomSpacing(10, after: rows.arrangedSubviews.last ?? rows)
        addFullWidth(hint)
    }

    // MARK: - Chrome

    /// The panel the list sits on — wide and tall enough to read at a glance from
    /// across the desk; it is the one thing on screen while ⌃ is held.
    static let panelWidth: CGFloat = 720

    private func buildPanel() {
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 16
        panel.layer?.borderWidth = 1
        panel.layer?.shadowOpacity = 0.4
        panel.layer?.shadowRadius = 32
        panel.layer?.shadowOffset = NSSize(width: 0, height: -10)
        panel.themedBackground = BoardTheme.cardFill
        panel.themedBorder = BoardTheme.cardStrokeStrong
        panel.themedShadow = .black
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        let preferredWidth = panel.widthAnchor.constraint(equalToConstant: Self.panelWidth)
        preferredWidth.priority = .init(490)   // below windowSizeStayPut: a narrow window wins

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        rows.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(rows)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            preferredWidth,
            panel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            rows.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            rows.topAnchor.constraint(equalTo: panel.topAnchor),
            rows.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
    }

    /// One task row, built for one job — picking the task you want: the waiting flag,
    /// the title, and where it runs — just the folder's name (the board's project
    /// label), so its length is predictable. The title takes the room; the folder
    /// gives way first. Colour carries information only: the chosen row is the one filled plate —
    /// a brand-tinted plate with a brand edge, the board's keyboard-focus blue — and a
    /// card that waits for you keeps a small red flag rather than a red row, so you see
    /// it is waiting without it pulling the eye off the row you are choosing.
    private func row(for card: BoardCard, highlighted: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.borderWidth = highlighted ? 2 : 0
        container.themedBackground = highlighted ? BoardTheme.selectionFill : .clear
        container.themedBorder = highlighted ? BoardTheme.brand : nil
        container.identifier = NSUserInterfaceItemIdentifier(highlighted ? "switcher-row-chosen" : "switcher-row")

        let title = label(card.title ?? BoardTheme.shortPath(card.projectDir),
                          font: .systemFont(ofSize: 17, weight: highlighted ? .semibold : .medium),
                          color: BoardTheme.textPrimary)
        title.setContentCompressionResistancePriority(.init(480), for: .horizontal)
        // The last component even of a `~/…` or far-side path — the board's label keeps
        // those whole — so every row's folder is one name.
        let folder = (BoardTheme.projectLabel(for: card) as NSString).lastPathComponent
        let directory = label(folder, font: .systemFont(ofSize: 13),
                              color: BoardTheme.textMuted)
        directory.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        directory.identifier = NSUserInterfaceItemIdentifier("switcher-directory")

        let line = NSStackView(views: [waitingFlag(card.state.needsAttention), title, NSView(), directory])
        line.spacing = 16
        line.setCustomSpacing(10, after: line.arrangedSubviews[0])
        line.alignment = .centerY
        line.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 16)
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    /// A 7pt NEEDS YOU dot for a card that waits for you; an empty slot of the same
    /// width otherwise, so every title starts on the same line.
    private func waitingFlag(_ waiting: Bool) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.themedBackground = waiting ? BoardTheme.needs : .clear
        dot.identifier = waiting ? NSUserInterfaceItemIdentifier("switcher-waiting-flag") : nil
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        return dot
    }

    private func addSeparator() {
        let line = NSView()
        line.wantsLayer = true
        line.themedBackground = BoardTheme.cardStroke
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        if let last = rows.arrangedSubviews.last { rows.setCustomSpacing(8, after: last) }
        addFullWidth(line)
        rows.setCustomSpacing(8, after: line)
    }

    private func addFullWidth(_ view: NSView) {
        rows.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -24).isActive = true
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.yieldWidthToWindow()
        return field
    }
}
