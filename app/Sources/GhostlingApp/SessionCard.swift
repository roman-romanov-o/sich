import AppKit
import GhostlingCore

/// A cmux-style board card (US-003 AC#2): flow badge, project dir, agent, and the
/// current detected state — rendered per the HELM POC card face. Single
/// responsibility: present one ``BoardCard`` and report clicks for drill-in
/// (US-002 AC#1). It holds no board logic; placement/attention live in
/// `GhostlingCore`.
@MainActor
final class SessionCard: NSView {
    let card: BoardCard
    /// Invoked on click — the board wires this to drill into the session (US-002).
    var onSelect: ((BoardCard) -> Void)?

    private let stack = NSStackView()

    init(card: BoardCard) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        configureLayer()
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Appearance

    private func configureLayer() {
        layer?.backgroundColor = BoardTheme.cardFill.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        // A waiting/blocked card gets the amber edge — the POC's structural
        // "this one needs you" cue, distinct from a normal card's hairline.
        let needsYou = card.state.needsAttention
        layer?.borderColor = (needsYou ? BoardTheme.attention : BoardTheme.cardStroke).cgColor
    }

    private func buildContent() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack.addArrangedSubview(headerRow())
        stack.addArrangedSubview(label(card.projectDir, font: BoardTheme.title, color: BoardTheme.textPrimary))
        stack.addArrangedSubview(footerRow())
        if let note = attentionNote() { stack.addArrangedSubview(note) }
    }

    /// `[A] · saha/task-04` — the flow badge + session id, as on the POC card top.
    private func headerRow() -> NSView {
        let row = NSStackView()
        row.spacing = 6
        row.addArrangedSubview(flowBadge())
        row.addArrangedSubview(label(card.sessionID, font: BoardTheme.mono, color: BoardTheme.textMuted))
        return row
    }

    /// `Claude Code            window` — agent on the left, flow descriptor right.
    private func footerRow() -> NSView {
        let row = NSStackView()
        row.spacing = 6
        row.addArrangedSubview(label(card.agent.displayName, font: BoardTheme.monoSmall, color: BoardTheme.textMuted))
        row.addArrangedSubview(NSView())   // flexible spacer
        let tag = card.flow == .a ? "SDK" : "window"
        row.addArrangedSubview(label(tag, font: BoardTheme.monoSmall, color: BoardTheme.textFaint))
        return row
    }

    private func flowBadge() -> NSView {
        let badge = label(card.flow.rawValue, font: BoardTheme.monoBold, color: BoardTheme.textPrimary)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor(white: 0.20, alpha: 1).cgColor
        badge.layer?.cornerRadius = 3
        badge.alignment = .center
        badge.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return badge
    }

    /// The card-level "blocked — needs a decision" / "waiting on you" line, only
    /// shown for attention states (US-005, made structural per the POC).
    private func attentionNote() -> NSView? {
        switch card.state {
        case .blocked:
            return label("⊘ blocked — needs a decision", font: BoardTheme.monoSmall, color: BoardTheme.attention)
        case .waitingForInput:
            return label("⌖ waiting on you", font: BoardTheme.monoSmall, color: BoardTheme.attention)
        default:
            return nil
        }
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        return field
    }

    // MARK: - Drill-in

    override func mouseDown(with event: NSEvent) {
        onSelect?(card)
    }
}
