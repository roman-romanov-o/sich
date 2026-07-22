import AppKit

/// The terminal font-size pill shown inside the drill-in and planning takeovers.
/// (The board's zoom pill is gone — board type is ⌘+/⌘− via the app menu plus
/// the automatic responsive scale.)
@MainActor
final class FontSizeControls: NSView {
    var onTerminalSmaller: (() -> Void)?
    var onTerminalLarger: (() -> Void)?

    private let terminal = NSTextField(labelWithString: "Terminal")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.cardFill.withAlphaComponent(0.72)
        layer?.cornerRadius = 6
        layer?.borderWidth = 0
        build()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 134, height: 30) }

    private func build() {
        terminal.font = BoardTheme.monoSmall
        terminal.textColor = BoardTheme.textMuted
        let row = NSStackView(views: [
            terminal, button("−", #selector(terminalSmaller)), button("+", #selector(terminalLarger)),
        ])
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

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = QuietBoardButton(title: title)
        button.target = self
        button.action = action
        button.font = BoardTheme.monoBold
        button.contentTintColor = BoardTheme.textPrimary
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    @objc private func terminalSmaller() { onTerminalSmaller?() }
    @objc private func terminalLarger() { onTerminalLarger?() }
}
