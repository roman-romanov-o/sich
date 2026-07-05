import AppKit
import GhostlingCore

/// The launchable, screenshottable quota window (US-006): hosts a ``QuotaPanel``
/// seeded with a representative four-pool fixture so the pixel AC ("the four
/// gauges render distinctly on screen") can be captured + human-signed-off.
///
/// It only renders display data — no recommender, no `saha run …` (that is the
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
        window.title = "Ghostling — quota"
        panel.frame = NSRect(origin: .zero, size: window.frame.size)
        panel.autoresizingMask = [.width, .height]
        let root = NSView(frame: panel.frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = BoardTheme.canvas.cgColor
        root.appearance = NSAppearance(named: .darkAqua)
        root.addSubview(panel)
        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
