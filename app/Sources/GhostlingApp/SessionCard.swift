import AppKit
import GhostlingCore

/// A cmux-style board card (US-003 AC#2): a coloured state rail, flow badge,
/// project dir, agent (with a colour dot), and the current detected state —
/// rendered in the Deep Slate palette. Single responsibility: present one
/// ``BoardCard``, report clicks for drill-in (US-002 AC#1), and act as the drag
/// source for a manual column move. Board logic stays in `GhostlingCore`.
@MainActor
final class SessionCard: NSView, NSDraggingSource {
    let card: BoardCard
    /// Invoked on click — the board wires this to drill into the session (US-002).
    var onSelect: ((BoardCard) -> Void)?

    private let stack = NSStackView()
    /// Distinguishes a click (drill-in) from a drag (column move): a drag sets
    /// this, so `mouseUp` does not also fire `onSelect`.
    private var didDrag = false

    init(card: BoardCard) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        configureLayer()
        addStateRail()
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Appearance

    private func configureLayer() {
        layer?.backgroundColor = BoardTheme.cardFill.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        // A waiting/blocked card gets a stronger edge in its state colour — the
        // structural "this one needs you" cue; a normal card keeps the slate stroke.
        let needsYou = card.state.needsAttention
        layer?.borderColor = (needsYou ? BoardTheme.stateColor(card.state) : BoardTheme.cardStroke).cgColor
    }

    /// Keyboard-focus ring (arrow-key board navigation): a brand-coloured 2pt
    /// edge while focused; un-focusing restores the state-derived border.
    func setKeyboardFocus(_ focused: Bool) {
        if focused {
            layer?.borderWidth = 2
            layer?.borderColor = BoardTheme.brand.cgColor
        } else {
            configureLayer()
        }
    }

    /// The 4px left rail in the card's state colour — the at-a-glance lifecycle
    /// cue; attention states get a soft glow so they pull the eye.
    private func addStateRail() {
        let rail = NSView()
        rail.wantsLayer = true
        let color = BoardTheme.stateColor(card.state)
        rail.layer?.backgroundColor = color.cgColor
        rail.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        rail.layer?.cornerRadius = 8
        if card.state.needsAttention {
            rail.layer?.masksToBounds = false
            rail.layer?.shadowColor = color.cgColor
            rail.layer?.shadowRadius = 5
            rail.layer?.shadowOpacity = 0.8
            rail.layer?.shadowOffset = .zero
        }
        rail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rail)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 4),
        ])
    }

    private func buildContent() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),  // clear the rail
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack.addArrangedSubview(headerRow())
        stack.addArrangedSubview(titleLabel())
        if let subtitle = projectSubtitle() { stack.addArrangedSubview(subtitle) }
        stack.addArrangedSubview(footerRow())
        if let note = attentionNote() { stack.addArrangedSubview(note) }
    }

    /// The card headline — the human task title the operator named this work
    /// ("Fix login redirect"), so the card reads as a *task*, not a raw terminal.
    /// Falls back to the project-dir leaf for an untitled (hook-observed) session.
    /// Wraps to two lines then truncates, since a real title rarely fits one.
    private func titleLabel() -> NSTextField {
        let text = card.title ?? BoardTheme.shortPath(card.projectDir)
        let field = label(text, font: BoardTheme.title, color: BoardTheme.textPrimary)
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = true
        field.cell?.truncatesLastVisibleLine = true
        field.preferredMaxLayoutWidth = 142   // card content width (170 − rail − insets)
        return field
    }

    /// The faint context line under a titled card: which project the work lives in.
    /// Only shown when a title gave the headline meaning — for an untitled card the
    /// project dir is already the headline, so repeating it would be noise.
    private func projectSubtitle() -> NSTextField? {
        guard card.title != nil else { return nil }
        return label("◇ \(BoardTheme.shortPath(card.projectDir))", font: BoardTheme.monoSmall, color: BoardTheme.textFaint)
    }

    /// `[A] · saha/task-04            ⠿` — flow badge + session id, with a faint,
    /// always-visible drag grip on the right so the card's draggability (manual
    /// column move) is discoverable, not a hidden gesture.
    private func headerRow() -> NSView {
        let row = NSStackView()
        row.spacing = 6
        row.addArrangedSubview(flowBadge())
        row.addArrangedSubview(label(card.sessionID, font: BoardTheme.mono, color: BoardTheme.textMuted))
        row.addArrangedSubview(NSView())   // flexible spacer
        row.addArrangedSubview(stateChip())
        let grip = label("⠿", font: BoardTheme.monoBold, color: BoardTheme.textFaint)
        grip.alphaValue = 0.55
        grip.toolTip = "drag to another column to move this card"
        row.addArrangedSubview(grip)
        return row
    }

    /// `● Claude Code            [SDK]` — agent dot + name left, the pool chip right.
    private func footerRow() -> NSView {
        let row = NSStackView()
        row.spacing = 6
        row.addArrangedSubview(agentDot())
        row.addArrangedSubview(label(card.agent.displayName, font: BoardTheme.monoSmall, color: BoardTheme.textMuted))
        row.addArrangedSubview(NSView())   // flexible spacer
        row.addArrangedSubview(poolChip())
        return row
    }

    /// Which Anthropic pool this card's work burns, as a tinted chip in the flow
    /// colour (Flow-A → violet "SDK" / Flow-B → teal "window") — so pool burn is
    /// legible on every card, not just a faint right-aligned word (US-006: pool is
    /// first-class on the card). ponytail: the `iter·phase` detail the designer also
    /// wants on Flow-A is a new card data dimension (task-02-estimation); the
    /// scrollback already carries it until the model field lands.
    private func poolChip() -> NSView {
        let color = BoardTheme.flowColor(card.flow)
        let chip = ChipLabel(text: card.flow == .a ? "SDK" : "window")
        chip.font = BoardTheme.monoSmall
        chip.textColor = color
        chip.alignment = .center
        chip.wantsLayer = true
        chip.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        chip.layer?.cornerRadius = 3
        return chip
    }

    /// A small tinted chip naming the card's lifecycle state in its state colour —
    /// so every card is self-describing at a glance, not only the attention ones
    /// (the 4px rail alone is a weak signal for idle/running/done).
    private func stateChip() -> NSView {
        let color = BoardTheme.stateColor(card.state)
        let chip = ChipLabel(text: stateChipLabel)
        chip.font = BoardTheme.monoSmall
        chip.textColor = color
        chip.alignment = .center
        chip.wantsLayer = true
        chip.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        chip.layer?.cornerRadius = 3
        return chip
    }

    /// Short, card-sized label for each state (the rawValue `waiting-for-input` is
    /// too wide for a chip).
    private var stateChipLabel: String {
        switch card.state {
        case .idle: return "idle"
        case .running: return "running"
        case .waitingForInput: return "waiting"
        case .runningTests: return "tests"
        case .blocked: return "blocked"
        case .done: return "done"
        case .unknown: return "?"
        }
    }

    private func flowBadge() -> NSView {
        let badge = label(card.flow.rawValue, font: BoardTheme.monoBold, color: BoardTheme.textPrimary)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = BoardTheme.flowColor(card.flow).withAlphaComponent(0.22).cgColor
        badge.layer?.cornerRadius = 3
        badge.alignment = .center
        badge.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return badge
    }

    /// A small dot in the agent's colour (Claude amber / Codex green / Gemini blue).
    private func agentDot() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = BoardTheme.agentColor(card.agent).cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        return dot
    }

    /// The card-level "blocked — needs a decision" / "waiting on you" line, only
    /// shown for attention states (US-005, made structural per the POC).
    private func attentionNote() -> NSView? {
        switch card.state {
        case .blocked:
            return label("⊘ blocked — needs a decision", font: BoardTheme.monoSmall, color: BoardTheme.stateColor(.blocked))
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

    // MARK: - Drill-in (click) + drag (move)

    override func mouseDown(with event: NSEvent) { didDrag = false }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        let item = NSPasteboardItem()
        item.setString(card.id.uuidString, forType: BoardCell.cardType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onSelect?(card) }
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }

    /// A bitmap of the card to drag under the cursor — a visual handle only, so the
    /// known-unfaithful `cacheDisplay` is fine here (not screenshot evidence).
    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return image }
        cacheDisplay(in: bounds, to: rep)
        image.addRepresentation(rep)
        return image
    }
}

/// A layer-backed text field that pads its text into a small rounded chip — the
/// same "the label draws its own fill" render path as the flow badge and the back
/// pill. A container `NSView` with a *child* label does NOT paint reliably on this
/// hand-painted dark UI (the iter-4 invisible-pill defect), so the chip IS the label.
@MainActor
final class ChipLabel: NSTextField {
    init(text: String) {
        super.init(frame: .zero)
        stringValue = text
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false   // the LAYER paints the fill
    }

    required init?(coder: NSCoder) { nil }

    /// Pad the intrinsic text size so the rounded fill has horizontal breathing room.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 12
        size.height += 3
        return size
    }
}
