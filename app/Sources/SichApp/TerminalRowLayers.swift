import AppKit
import SichCore

/// The terminal viewport as one opaque `CALayer` per row, each showing a cached
/// row image. Scrolling then costs a handful of `contents` pointer swaps and a
/// GPU composite — no Core Text, and no Core Animation display-list rasterization
/// of forty rows of glyphs per frame, which is what capped the old `draw(_:)`
/// path below the display's refresh rate even when the main thread was idle.
///
/// Hosted in its own view so AppKit never reorders these sublayers against the
/// surface's subviews; the overlay view above it carries everything that is not
/// a row (selection, cursor, end banner, scrollback pill).
///
/// The last layer is a spare row parked just BELOW the host's bottom edge: a
/// sub-row scroll shifts the whole stack up by a fraction of a row
/// (``setScrollOffset(_:)``), sliding that spare row in at the bottom while the
/// host clips the top row's overflow. Grid row `r` is layer `r`.
@MainActor
final class TerminalRowLayerHost: NSView {
    private var rows: [CALayer] = []
    /// What each row layer currently shows, by identity — the same image object
    /// is never re-assigned, so Core Animation keeps its texture.
    private var shown: [CGImage?] = []

    /// Implicit animations would cross-fade every scroll step; kill them per key.
    private static let noActions: [String: CAAction] = [
        "contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(),
        "position": NSNull(), "contentsScale": NSNull()
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true   // the clip for the shifted stack
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Rows never take events; the surface behind them owns the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Size the row stack: `count` layers of `rowSize` points stacked from the top
    /// edge (the last one past the bottom), at the window's backing scale so a 2x
    /// image maps 1:1 onto device pixels.
    func layout(rowCount count: Int, rowSize: CGSize, scale: CGFloat) {
        guard let layer else { return }
        while rows.count > count {
            rows.removeLast().removeFromSuperlayer()
            shown.removeLast()
        }
        while rows.count < count {
            let row = CALayer()
            row.actions = Self.noActions
            row.isOpaque = true
            row.anchorPoint = .zero
            row.isHidden = true          // a new row shows nothing until `show` gives it an image
            layer.addSublayer(row)
            rows.append(row)
            shown.append(nil)
        }
        for (index, row) in rows.enumerated() {
            row.contentsScale = scale
            row.frame = CGRect(x: 0, y: CGFloat(index) * rowSize.height,
                               width: rowSize.width, height: rowSize.height)
        }
    }

    /// Slide the whole stack up by `points` (a fraction of a row during a smooth
    /// scroll) — the clip view's bounds origin moves, no row layer is touched.
    func setScrollOffset(_ points: CGFloat) {
        guard bounds.origin.y != points else { return }
        setBoundsOrigin(NSPoint(x: 0, y: points))
    }

    /// Show `image` on `row`; `nil` hides the row (a blank line is the surface's
    /// own background). Same image object → nothing is touched.
    func show(_ image: CGImage?, atRow row: Int) {
        guard rows.indices.contains(row), shown[row] !== image else { return }
        shown[row] = image
        rows[row].contents = image
        rows[row].isHidden = image == nil
    }

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var rowCount: Int { rows.count }
}

/// Everything drawn over the rows — selection, cursor, end banner, scrollback
/// pill — in a plain flipped `draw(_:)`, exactly as the surface used to paint it.
/// Transparent and event-free; the surface draws through `drawHandler`.
@MainActor
final class TerminalOverlayView: NSView {
    var drawHandler: (NSRect) -> Void = { _ in }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawHandler(dirtyRect)
    }
}

/// One rendered row, keyed by what it shows — not where. A viewport scroll moves
/// rows without changing them, so every row that was on screen last frame is a
/// hit, and only genuinely new content pays for Core Text layout. The palette the
/// cells resolve against is not part of the key: a palette change (appearance,
/// an OSC 10/11 default-colour change) empties the cache instead.
struct TerminalRowKey: Hashable {
    let cells: [TerminalCell]
    let scale: CGFloat
}

/// Content-keyed cache of row images with generation-based trimming: once it
/// grows past the cap, only rows used by the current frame survive, so a long
/// scroll never re-renders a whole screen in one go the way a clear-all would.
@MainActor
final class TerminalRowCache {
    private struct Entry {
        let image: CGImage
        var lastUsed: Int
    }

    private var entries: [TerminalRowKey: Entry] = [:]
    private(set) var generation = 0
    private(set) var hits = 0
    private(set) var misses = 0

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var count: Int { entries.count }

    func beginFrame() { generation += 1 }

    func image(for key: TerminalRowKey, render: (TerminalRowKey) -> CGImage?) -> CGImage? {
        if var entry = entries[key] {
            entry.lastUsed = generation
            entries[key] = entry
            hits += 1
            return entry.image
        }
        guard let image = render(key) else { return nil }
        entries[key] = Entry(image: image, lastUsed: generation)
        misses += 1
        return image
    }

    /// Drop rows the current frame did not use, but only once the cache is over
    /// `capacity` — below it, rows just scrolled off stay warm for the way back.
    func trim(capacity: Int) {
        guard entries.count > capacity else { return }
        entries = entries.filter { $0.value.lastUsed == generation }
    }

    func removeAll() { entries.removeAll() }
}
