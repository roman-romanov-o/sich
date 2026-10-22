import AppKit

/// The DONE column folded to a narrow rail: the header's pieces — fold toggle,
/// count, archive icon, a sideways title — stacked top-down. The board hands in
/// the two buttons it already builds for the expanded header, and reads the
/// count back through ``countLabel`` like any other column caption.
@MainActor
final class DoneRail: NSView {
    let countLabel: NSTextField

    init(toggle: NSButton, archive: NSButton) {
        let count = NSTextField(labelWithString: "")
        count.font = BoardTheme.numeric
        count.textColor = BoardTheme.textFaint
        count.lineBreakMode = .byTruncatingTail
        countLabel = count
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("done-rail")
        wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
        stack.addArrangedSubview(toggle)
        stack.addArrangedSubview(count)
        stack.addArrangedSubview(archive)
        stack.addArrangedSubview(VerticalCapsLabel(text: BoardView.ColumnGroup.done.title))
    }

    required init?(coder: NSCoder) { nil }
}

/// The board's borderless SF Symbol buttons (add task, archive, DONE fold) share
/// one recipe. The 30pt box is yielded to the window (see `yieldWidthToWindow`):
/// a required size here would become a header minimum that the equal-width
/// columns multiply into a window-wide floor the operator can't drag below. At
/// priority 490 the symbol scales down instead of pinning the window.
@MainActor
enum BoardSymbolButton {
    static func make(
        symbol: String, pointSize: CGFloat, tint: NSColor, identifier: String,
        description: String, target: AnyObject, action: Selector
    ) -> NSButton {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        let button = NSButton(image: image ?? NSImage(), target: target, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.title = ""
        button.toolTip = description
        button.setAccessibilityLabel(description)
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.contentTintColor = tint
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        button.yieldWidthToWindow()
        let width = button.widthAnchor.constraint(equalToConstant: 30)
        let height = button.heightAnchor.constraint(equalToConstant: 30)
        width.priority = .init(490)
        height.priority = .init(490)
        NSLayoutConstraint.activate([width, height])
        return button
    }
}

/// Column signage turned on its side for the folded DONE rail: the caps title
/// drawn bottom-to-top, sized so Auto Layout sees a tall, thin box. Drawing (not
/// a rotated `NSTextField`) keeps the frame and the glyphs in agreement.
@MainActor
final class VerticalCapsLabel: NSView, ThemeReapplying {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { nil }

    private var caps: NSAttributedString { BoardTheme.caps(text, color: BoardTheme.textMuted) }

    override var intrinsicContentSize: NSSize {
        let size = caps.size()
        return NSSize(width: ceil(size.height), height: ceil(size.width))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = caps.size()
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: .pi / 2)
        caps.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2))
        context.restoreGState()
    }

    /// The colour resolves at draw time; a flip just needs a redraw, and the font
    /// scale may have changed the box.
    func reapplyTheme(under appearance: NSAppearance) {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}
