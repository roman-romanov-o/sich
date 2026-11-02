import AppKit
import SichCore

/// The window's titlebar while a card is open: a unified `NSToolbar` that shares the
/// row with the traffic lights. On the leading edge a navigational "‹ Board ⌘[" item
/// (where macOS puts Back); in the middle, centred on the window, the task — its
/// title, then where it runs — on one quiet plate (``TaskPlate``), so the first thing
/// you see after switching is which task you switched to.
///
/// The toolbar is hidden on the board, so the board keeps its plain titlebar. AppKit
/// draws and lays out the row (dragging, double-click zoom, full screen, right-to-left);
/// the shell only says what to show. While a task is up the window also takes the
/// terminal's paper (the titlebar and the terminal read as one surface) and the task
/// as its — hidden — `title`, for the Window menu, Mission Control and VoiceOver.
@MainActor
final class TaskTitlebar: NSObject, NSToolbarDelegate {
    static let backItem = NSToolbarItem.Identifier("sich.titlebar.back")
    static let taskItem = NSToolbarItem.Identifier("sich.titlebar.task")

    let toolbar = NSToolbar(identifier: "sich.titlebar")
    /// Internal so a test can click it through the control's own action path.
    let backButton = NSButton()
    let plate = TaskPlate()
    /// "‹ Board" was clicked.
    var onBack: (() -> Void)?
    private weak var window: NSWindow?
    /// The window's own title and paper on the board, put back by ``hide()``.
    private var boardTitle = ""
    private var boardBackground: NSColor?

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.taskItem]
        toolbar.isVisible = false
        configureBackButton()
    }

    /// Put the toolbar on `window`: one unified row with the traffic lights, no rule
    /// under it — the titlebar and the terminal below are one surface.
    func install(on window: NSWindow) {
        self.window = window
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        toolbar.isVisible = false   // attaching shows it; the board starts without it
    }

    /// Show the open task. Keeps the window's frame: the toolbar row grows the titlebar
    /// into the content area rather than the window into the screen.
    func show(title: String, directory: String) {
        plate.set(title: title, directory: directory)
        guard let window else { return }
        if !isShowing {
            boardTitle = window.title
            boardBackground = window.backgroundColor
        }
        window.title = title
        window.backgroundColor = BoardTheme.termBg
        setVisible(true)
    }

    /// Back on the board: the titlebar goes back to just the traffic lights.
    func hide() {
        guard let window, isShowing else { return }
        window.title = boardTitle
        if let boardBackground { window.backgroundColor = boardBackground }
        setVisible(false)
    }

    /// Whether a task is up — tracked here, not read off `toolbar.isVisible`, which
    /// AppKit flips on its own when the toolbar is attached.
    private(set) var isShowing = false

    private func setVisible(_ visible: Bool) {
        guard let window, isShowing != visible else { return }
        isShowing = visible
        let frame = window.frame
        toolbar.isVisible = visible
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    /// What the plate says about where a card runs: the folder, `~`-abbreviated, or
    /// `host:folder` for a remote card.
    static func directory(of card: BoardCard) -> String {
        if let destination = card.remoteDestination {
            return "\(BoardTheme.shortDestination(destination)):\(card.remoteDir ?? "~")"
        }
        return (card.projectDir as NSString).abbreviatingWithTildeInPath
    }

    private func configureBackButton() {
        backButton.bezelStyle = .toolbar
        backButton.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.attributedTitle = Self.backTitle
        backButton.toolTip = "Back to the board (⌘[)"
        backButton.setAccessibilityLabel("Back to the board")
        backButton.target = self
        backButton.action = #selector(back)
    }

    /// "Board", then its shortcut in the quieter label ink.
    private static var backTitle: NSAttributedString {
        let title = NSMutableAttributedString(
            string: "Board", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        title.append(NSAttributedString(
            string: "  ⌘[", attributes: [.font: NSFont.systemFont(ofSize: 11),
                                         .foregroundColor: NSColor.tertiaryLabelColor]))
        return title
    }

    @objc private func back() { onBack?() }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.backItem, .flexibleSpace, Self.taskItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.backItem:
            item.view = backButton
            item.label = "Board"
            item.isNavigational = true   // the leading edge, beside the traffic lights
        case Self.taskItem:
            item.view = plate
            item.label = "Task"
            item.visibilityPriority = .high   // the last thing to fall into overflow
        default:
            return nil
        }
        return item
    }
}

/// The task on its plate: the title in the primary ink, then the folder in the faint
/// one, on one line. The folder gives way first (truncating its start, so the leaf
/// stays) and the title only after it. A faint fill and hairline set it apart from the
/// titlebar without a hue — the board's one colour stays NEEDS YOU's.
@MainActor
final class TaskPlate: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let directoryField = NSTextField(labelWithString: "")

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var titleForTesting: String { titleField.stringValue }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var directoryForTesting: String { directoryField.stringValue }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        themedBackground = BoardTheme.textPrimary.withAlphaComponent(0.07)
        themedBorder = BoardTheme.textPrimary.withAlphaComponent(0.06)

        titleField.font = .systemFont(ofSize: 16, weight: .semibold)
        titleField.textColor = BoardTheme.textPrimary
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        directoryField.font = .systemFont(ofSize: 13)
        directoryField.textColor = BoardTheme.textFaint
        directoryField.lineBreakMode = .byTruncatingHead
        directoryField.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        let row = NSStackView(views: [titleField, directoryField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func set(title: String, directory: String) {
        titleField.stringValue = title
        directoryField.stringValue = directory
        directoryField.toolTip = directory
        toolTip = title
    }

    /// The plate sits in the titlebar, outside the content view's theme walk
    /// (``ThemedRootView``), so it follows a light/dark flip itself.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reapplyThemedColors()
    }
}
