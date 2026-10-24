import AppKit
import SichCore

/// The launchable, screenshottable quota window (US-006): hosts a ``QuotaPanel``
/// seeded with a representative four-pool fixture so the pixel AC ("the four
/// gauges render distinctly on screen") can be captured + human-signed-off.
///
/// It only renders display data — no recommender, no dispatch (that is the
/// deferred allocator, US-007/US-009). The sources are injected stubs; the window
/// spends no quota to draw.
@MainActor
public final class QuotaShell: NSObject, NSApplicationDelegate {
    private let sources: [QuotaSourceInput]
    private var window: NSWindow?
    let panel = QuotaPanel()

    /// - Parameter sources: the stubbed quota sources to render (defaults to the
    ///   demo four-pool fixture used for the screenshot).
    public init(sources: [QuotaSourceInput] = QuotaSeed.demo) {
        self.sources = sources
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        panel.render(gauges: QuotaProjection.gauges(from: sources))
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Sich — quota"
        panel.frame = NSRect(origin: .zero, size: window.frame.size)
        panel.autoresizingMask = [.width, .height]
        // A `ThemedRootView` so this standalone window gets the same live light/dark
        // re-resolve as the board's: its own appearance hook drives the whole subtree.
        let root = ThemedRootView(frame: panel.frame)
        root.themedBackground = BoardTheme.canvas
        // Follow the system appearance (don't pin `.darkAqua`) — `BoardTheme`'s tokens
        // resolve light/dark themselves, so the standalone quota window follows too.
        root.addSubview(panel)
        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
