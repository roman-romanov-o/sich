import AppKit

@MainActor
final class FontSizeControls: NSView {
    enum Scope {
        case board
        case terminal
        case both
    }

    var onBoardSmaller: (() -> Void)?
    var onBoardLarger: (() -> Void)?
    var onTerminalSmaller: (() -> Void)?
    var onTerminalLarger: (() -> Void)?

    private let scope: Scope
    private let board = NSTextField(labelWithString: "Board")
    private let terminal = NSTextField(labelWithString: "Terminal")

    init(scope: Scope = .both) {
        self.scope = scope
        super.init(frame: .zero)
        commonInit()
    }

    override init(frame frameRect: NSRect) {
        self.scope = .both
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        switch scope {
        case .board:
            return NSSize(width: 112, height: 30)
        case .terminal:
            return NSSize(width: 134, height: 30)
        case .both:
            return NSSize(width: 242, height: 30)
        }
    }

    private func commonInit() {
        wantsLayer = true
        themedBackground = BoardTheme.cardFill.withAlphaComponent(0.72)
        themedBorder = BoardTheme.cardStroke
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        build()
    }

    private func build() {
        let row = NSStackView(views: controlViews())
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func controlViews() -> [NSView] {
        switch scope {
        case .board:
            return boardControls()
        case .terminal:
            return terminalControls()
        case .both:
            return boardControls() + [divider()] + terminalControls()
        }
    }

    private func boardControls() -> [NSView] {
        [label(board), button("−", #selector(boardSmaller)), button("+", #selector(boardLarger))]
    }

    private func terminalControls() -> [NSView] {
        [label(terminal), button("−", #selector(terminalSmaller)), button("+", #selector(terminalLarger))]
    }

    private func label(_ field: NSTextField) -> NSTextField {
        field.font = BoardTheme.monoSmall
        field.textColor = BoardTheme.textMuted
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.font = BoardTheme.monoBold
        button.contentTintColor = BoardTheme.textPrimary
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func divider() -> NSView {
        let view = NSView()
        view.themedBackground = BoardTheme.hairline
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return view
    }

    @objc private func boardSmaller() { onBoardSmaller?() }
    @objc private func boardLarger() { onBoardLarger?() }
    @objc private func terminalSmaller() { onTerminalSmaller?() }
    @objc private func terminalLarger() { onTerminalLarger?() }
}
