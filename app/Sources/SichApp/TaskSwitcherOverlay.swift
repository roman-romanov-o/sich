import AppKit
import SichCore

/// The Ctrl+Tab switcher overlay (VS Code style): a centred panel listing drillable
/// tasks — NEEDS YOU cards first, most-recently-focused first within each tier — with
/// one highlighted row. The shell steps the highlight on held-⌃ presses and commits on
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
        rows.addArrangedSubview(label(
            "⇥ next · ⇧⇥ previous · release ⌃ to switch · esc cancels",
            font: BoardTheme.sansTiny, color: BoardTheme.textDim))
    }

    // MARK: - Chrome

    private func buildPanel() {
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.borderWidth = 1
        panel.layer?.shadowOpacity = 0.35
        panel.layer?.shadowRadius = 24
        panel.layer?.shadowOffset = NSSize(width: 0, height: -8)
        panel.themedBackground = BoardTheme.cardFill
        panel.themedBorder = BoardTheme.cardStrokeStrong
        panel.themedShadow = .black
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        rows.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(rows)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -60),
            panel.widthAnchor.constraint(equalToConstant: 540),
            rows.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            rows.topAnchor.constraint(equalTo: panel.topAnchor),
            rows.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
    }

    /// One task row: title left; project anchor (colour = project identity) and the
    /// status stamp right. NEEDS YOU rows carry their column's amber fill so the tier
    /// reads instantly; the highlight is a brand-blue edge, matching keyboard focus
    /// on the board.
    private func row(for card: BoardCard, highlighted: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        let needs = card.state.needsAttention
        container.themedBackground = needs ? BoardTheme.needsYouCard
            : highlighted ? BoardTheme.cardFillRaised : .clear
        container.layer?.borderWidth = highlighted ? 1.5 : needs ? 1 : 0
        container.themedBorder = highlighted ? BoardTheme.brand
            : needs ? BoardTheme.needsYouStroke : nil

        let line = NSStackView()
        line.spacing = 8
        line.alignment = .firstBaseline
        line.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.addArrangedSubview(label(card.title ?? BoardTheme.shortPath(card.projectDir),
                                      font: BoardTheme.sansStrong, color: BoardTheme.textPrimary))
        line.addArrangedSubview(NSView())   // flexible spacer
        line.addArrangedSubview(label(BoardTheme.projectLabel(card.projectDir),
                                      font: BoardTheme.chip,
                                      color: BoardTheme.repoColor(for: card)))
        line.addArrangedSubview(statusLabel(for: card))

        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    /// "waiting 12m" / "blocked 3m" in the attention colours; anything else is a calm
    /// dim word — per the board's "only waiting gets a loud label" design rule.
    private func statusLabel(for card: BoardCard) -> NSTextField {
        switch card.state {
        case .waitingForInput:
            return label(stamp("waiting", card), font: BoardTheme.mono, color: BoardTheme.attention)
        case .blocked:
            return label(stamp("blocked", card), font: BoardTheme.mono, color: BoardTheme.alert)
        default:
            return label(Self.calmStateWord(card.state),
                         font: BoardTheme.monoSmall, color: BoardTheme.textFaint)
        }
    }

    private func stamp(_ word: String, _ card: BoardCard) -> String {
        [word, Self.age(card)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func calmStateWord(_ state: CardState) -> String {
        switch state {
        case .running: return "working"
        case .runningTests: return "tests"
        case .idle: return "idle"
        case .done: return "done"
        // Never blank: a card whose host stopped answering must say so here too,
        // or the switcher becomes the one surface still showing stale calm (US-007).
        case .unreachable: return "unreachable"
        default: return ""
        }
    }

    /// Compact "12m" / "1h 04m" age (same rendering as the card face); empty when the
    /// card carries no observation time (`.distantPast`).
    static func age(_ card: BoardCard) -> String {
        guard card.updatedAt > .distantPast else { return "" }
        let minutes = max(0, Int(Date().timeIntervalSince(card.updatedAt)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    private func addSeparator() {
        let line = NSView()
        line.wantsLayer = true
        line.themedBackground = BoardTheme.hairline
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        addFullWidth(line)
    }

    private func addFullWidth(_ view: NSView) {
        rows.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -20).isActive = true
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
