import AppKit

/// Persisted pane-layout preferences: divider positions and hidden rails. Same
/// injectable-`UserDefaults` seam as `RecentFolderStore` — production reads
/// `.standard`, a test points it at a scratch suite so a drag in a test never
/// touches the operator's real layout.
struct PaneLayoutStore {
    var defaults: UserDefaults = .standard

    static let planningTerminalWidthKey = "sich.planning.terminalWidth"
    static let planningRailHiddenKey = "sich.planning.reviewRailHidden"

    func width(forKey key: String, default fallback: CGFloat) -> CGFloat {
        let stored = CGFloat(defaults.double(forKey: key))
        return stored > 0 ? stored : fallback
    }

    func setWidth(_ width: CGFloat, forKey key: String) {
        defaults.set(Double(width), forKey: key)
    }

    func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// A thin vertical grab strip between two panes. It owns no geometry itself — the
/// hosting view mutates a stored width constraint from the drag deltas — so pane
/// layout stays the plain constraint math this hand-painted UI is built on (there
/// is no NSSplitView to inherit from). Custom-drawn and layer-backed like the rest
/// of the chrome.
final class PaneDivider: NSView {
    var onDragStart: (() -> Void)?
    /// Horizontal distance from the drag's start, in window points (right = positive).
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    static let thickness: CGFloat = 7

    private let grip = NSView()
    private var dragOriginX: CGFloat?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        themedBackground = BoardTheme.documentChrome
        grip.wantsLayer = true
        grip.themedBackground = BoardTheme.hairline
        grip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grip)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.thickness),
            grip.widthAnchor.constraint(equalToConstant: 1),
            grip.centerXAnchor.constraint(equalTo: centerXAnchor),
            grip.topAnchor.constraint(equalTo: topAnchor),
            grip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// The whole strip is the grab target — the 1pt grip line must never steal the hit.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragOriginX = event.locationInWindow.x
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOriginX else { return }
        onDrag?(event.locationInWindow.x - dragOriginX)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOriginX != nil else { return }
        dragOriginX = nil
        onDragEnd?()
    }
}
