import AppKit
import SichCore

/// First-launch setup: "which agent will run your tasks?". Shown over the board when
/// no agent CLI can be started (and on demand from Sich ▸ Set Up Agents…). One row per
/// agent with ONE action — Install, or a quiet "ready" — so a Mac that already has an
/// agent never sees this, and a fresh one is a single click from a working card.
///
/// Sign-in is not a step here: each agent signs you in on its first run, inside the
/// card's own terminal. A dumb view — the shell runs installers and owns the inventory.
final class AgentSetupSheet: NSView {
    enum RowState: Equatable {
        case ready(path: String)
        case missing
        case installing(line: String)
        case failed(line: String)

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    var onInstall: ((CardAgent) -> Void)?
    var onStart: (() -> Void)?
    var onSkip: (() -> Void)?

    private let card = NSView()
    private let list = NSStackView()
    private let startPill = SetupPill(title: "Start a task  ↵", style: .primary)
    private let skipPill = SetupPill(title: "Skip for now", style: .plain)
    private(set) var rows: [CardAgent: AgentSetupRow] = [:]
    private(set) var states: [CardAgent: RowState] = [:]

    init(states: [CardAgent: RowState]) {
        super.init(frame: .zero)
        buildChrome()
        update(states)
    }
    required init?(coder: NSCoder) { nil }

    var canStart: Bool { states.values.contains(where: \.isReady) }

    func update(_ states: [CardAgent: RowState]) {
        self.states = states
        let recommend = !canStart
        for agent in AgentInventory.offered {
            rows[agent]?.render(states[agent] ?? .missing,
                                recommended: recommend && agent == AgentInventory.offered.first)
        }
        startPill.isEnabledPill = canStart
    }

    // MARK: keyboard — ↵ starts, esc skips

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: if canStart { onStart?() }   // return, enter
        case 53: onSkip?()                         // esc
        default: super.keyDown(with: event)
        }
    }
    // The scrim swallows clicks so nothing under the sheet reacts to them.
    override func mouseDown(with event: NSEvent) {}

    // MARK: chrome

    private func buildChrome() {
        wantsLayer = true
        themedBackground = NSColor.black.withAlphaComponent(0.62)
        card.wantsLayer = true
        card.themedBackground = BoardTheme.cardFill
        card.themedBorder = BoardTheme.cardStrokeStrong
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 12
        card.layer?.shadowColor = .black
        card.layer?.shadowOpacity = 0.55
        card.layer?.shadowRadius = 32
        card.layer?.shadowOffset = CGSize(width: 0, height: -12)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 520),
        ])

        let eyebrow = makeMono(9)
        eyebrow.stringValue = "WELCOME TO SICH"
        eyebrow.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        eyebrow.textColor = BoardTheme.textFaint
        let title = makeSans(17, weight: .semibold)
        title.stringValue = "Pick an agent to run your tasks"
        let lede = makeSans(12, weight: .regular)
        lede.stringValue = "Every card runs a coding agent in its own terminal. Install one to start. "
            + "It signs you in the first time it runs."
        lede.textColor = BoardTheme.textFaint
        lede.lineBreakMode = .byWordWrapping
        lede.maximumNumberOfLines = 0
        lede.preferredMaxLayoutWidth = 520 - 40
        let head = NSStackView(views: [eyebrow, title, lede])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 6
        head.setCustomSpacing(4, after: eyebrow)
        head.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for agent in AgentInventory.offered {
            let row = AgentSetupRow(agent: agent)
            row.onInstall = { [weak self] in self?.onInstall?(agent) }
            rows[agent] = row
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -20).isActive = true
        }

        startPill.onClick = { [weak self] in
            guard let self, self.canStart else { return }
            self.onStart?()
        }
        skipPill.onClick = { [weak self] in self?.onSkip?() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let foot = NSStackView(views: [skipPill, spacer, startPill])
        foot.alignment = .centerY
        foot.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 16)

        let stack = NSStackView(views: [head, hairline(), list, hairline(), foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        pin(stack, to: card)
        for section in [head, list, foot] { section.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true }
    }

    private func hairline() -> NSView {
        let rule = NSView()
        rule.wantsLayer = true
        rule.themedBackground = BoardTheme.hairline
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rule.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return rule
    }
}

/// One agent: logo, name, where it lives (or its live install output), and its single
/// action on the right.
final class AgentSetupRow: NSView {
    var onInstall: (() -> Void)?

    private let title = makeSans(13, weight: .semibold)
    private let badgeTag = makeMono(9)
    private let detail = makeMono(10)
    private let action = SetupPill(title: "Install", style: .secondary)
    private let status = makeMono(10)

    init(agent: CardAgent) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        title.stringValue = agent.displayName
        badgeTag.stringValue = "RECOMMENDED"
        badgeTag.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        badgeTag.textColor = BoardTheme.attention
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        action.onClick = { [weak self] in self?.onInstall?() }

        let nameLine = NSStackView(views: [title, badgeTag])
        nameLine.spacing = 8
        nameLine.alignment = .firstBaseline
        let text = NSStackView(views: [nameLine, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let badge = HarnessBadge(agent: agent, pointSize: 20)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [badge, text, spacer, status, action])
        line.alignment = .centerY
        line.spacing = 12
        line.setCustomSpacing(8, after: spacer)
        line.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 8)
        pin(line, to: self)
    }
    required init?(coder: NSCoder) { nil }

    func render(_ state: AgentSetupSheet.RowState, recommended: Bool) {
        badgeTag.isHidden = !recommended
        detail.textColor = BoardTheme.textDim
        switch state {
        case let .ready(path):
            detail.stringValue = (path as NSString).abbreviatingWithTildeInPath
            status.stringValue = "✓ ready"
            status.textColor = BoardTheme.focusInk
            action.isHidden = true
        case .missing:
            detail.stringValue = "not installed"
            status.stringValue = ""
            action.title = "Install"
            action.isHidden = false
            action.isEnabledPill = true
        case let .installing(line):
            detail.stringValue = line.isEmpty ? "downloading…" : line
            status.stringValue = ""
            action.title = "Installing…"
            action.isHidden = false
            action.isEnabledPill = false
        case let .failed(line):
            detail.stringValue = line.isEmpty ? "install failed" : line
            detail.textColor = BoardTheme.alert
            status.stringValue = ""
            action.title = "Retry"
            action.isHidden = false
            action.isEnabledPill = true
        }
        status.isHidden = status.stringValue.isEmpty
    }

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var actionForTesting: SetupPill { action }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var detailText: String { detail.stringValue }
}

/// A layer-backed text-field pill — the same proven-to-composite idiom as
/// ``BackPill`` (a stock NSButton renders washed out on this hand-painted UI).
final class SetupPill: NSTextField {
    enum Style { case primary, secondary, plain }

    var onClick: (() -> Void)?
    var isEnabledPill = true { didSet { restyle() } }
    var title: String {
        get { stringValue }
        set { stringValue = newValue; invalidateIntrinsicContentSize() }
    }
    private let style: Style

    init(title: String, style: Style) {
        self.style = style
        super.init(frame: .zero)
        useCenteredTextCell()
        stringValue = title
        font = .systemFont(ofSize: 12, weight: style == .plain ? .regular : .semibold)
        alignment = .center
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        wantsLayer = true
        layer?.cornerRadius = 7
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += style == .plain ? 12 : 26
        size.height = 28
        return size
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func resetCursorRects() {
        if isEnabledPill { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if isEnabledPill { onClick?() }
    }

    private func restyle() {
        let accent = BoardTheme.attention
        layer?.borderWidth = style == .secondary ? 1 : 0
        switch style {
        case .primary:
            themedBackground = isEnabledPill ? accent : BoardTheme.canvasSunken
            textColor = isEnabledPill ? .white : BoardTheme.textDim
        case .secondary:
            themedBackground = isEnabledPill ? accent.withAlphaComponent(0.08) : .clear
            themedBorder = isEnabledPill ? accent.withAlphaComponent(0.45) : BoardTheme.cardStroke
            textColor = isEnabledPill ? accent : BoardTheme.textDim
        case .plain:
            themedBackground = .clear
            textColor = BoardTheme.textFaint
        }
        window?.invalidateCursorRects(for: self)
    }
}
