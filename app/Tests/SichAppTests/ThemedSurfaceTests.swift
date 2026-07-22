import AppKit
import Testing

@testable import SichApp

/// The bug these pin down: a `CALayer` can't hold a dynamic `NSColor`. `.cgColor`
/// resolves once, against whatever appearance was current on that line, and the layer
/// keeps that value forever — so on a light/dark flip the themed *text* re-coloured and
/// every layer-backed *fill* did not. The drill-in sidebar stayed light paper under a
/// dark terminal.
///
/// Every test here flips a real `NSAppearance` and lets AppKit dispatch
/// `viewDidChangeEffectiveAppearance` itself. Calling `reapplyThemedColors()` by hand
/// would assert the maths and leave the wiring — the part that actually broke — unproven.
///
/// Each one also *establishes* a starting side before flipping. Without that they'd
/// inherit whatever mode the machine running them happens to be in, and assigning the
/// appearance it already has dispatches nothing — the test would pass by never flipping.
@MainActor
@Suite("Themed surfaces follow a live light/dark flip")
struct ThemedSurfaceTests {

    /// What `color` resolves to under `name`, via the same drawing-appearance path the
    /// production code uses — so a test failure means the wiring is wrong, not that the
    /// test hardcoded a hex the theme is free to change.
    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) throws -> CGColor {
        var out: CGColor?
        try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
            out = color.cgColor
        }
        return try #require(out)
    }

    @Test("a fill re-resolves on a flip instead of freezing at the appearance it was built in")
    func fillFollowsFlip() throws {
        let root = ThemedRootView()
        let view = NSView()
        root.addSubview(view)
        root.appearance = NSAppearance(named: .darkAqua)
        view.themedBackground = BoardTheme.canvas

        let onPaper = try resolved(BoardTheme.canvas, .aqua)
        let onNight = try resolved(BoardTheme.canvas, .darkAqua)
        #expect(view.layer?.backgroundColor == onNight)

        root.appearance = NSAppearance(named: .aqua)
        #expect(view.layer?.backgroundColor == onPaper)

        root.appearance = NSAppearance(named: .darkAqua)
        #expect(view.layer?.backgroundColor == onNight)
    }

    @Test("the regression itself: the drill-in sidebar no longer stays light under a dark terminal")
    func sidebarFollowsFlip() throws {
        let root = ThemedRootView()
        root.appearance = NSAppearance(named: .darkAqua)
        let sidebar = DrillInSidebar(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        root.addSubview(sidebar)

        let paperSidebar = try resolved(BoardTheme.canvasSunken, .aqua)
        let nightSidebar = try resolved(BoardTheme.canvasSunken, .darkAqua)

        // Light paper — the state the screenshot was taken in...
        root.appearance = NSAppearance(named: .aqua)
        #expect(sidebar.layer?.backgroundColor == paperSidebar)

        // ...then the user switches the system to dark. The sidebar must move with it.
        root.appearance = NSAppearance(named: .darkAqua)
        #expect(sidebar.layer?.backgroundColor == nightSidebar)
        #expect(sidebar.layer?.backgroundColor != paperSidebar)
    }

    @Test("the walk reaches a deeply nested fill, not just the root's direct children")
    func flipReachesNestedSubviews() throws {
        let root = ThemedRootView()
        let middle = NSView()
        let leaf = NSView()
        root.addSubview(middle)
        middle.addSubview(leaf)
        root.appearance = NSAppearance(named: .aqua)
        leaf.themedBorder = BoardTheme.cardStroke

        let nightStroke = try resolved(BoardTheme.cardStroke, .darkAqua)
        root.appearance = NSAppearance(named: .darkAqua)
        #expect(leaf.layer?.borderColor == nightStroke)
    }

    @Test("a cleared colour is forgotten, not resurrected by the next flip")
    func clearedColourStaysCleared() throws {
        // The board's drop ring clears this way. If `nil` only cleared the layer and left
        // the colour remembered, the next flip would paint the ring back onto a cell the
        // user isn't dragging over.
        let root = ThemedRootView()
        root.appearance = NSAppearance(named: .aqua)
        let cell = NSView()
        root.addSubview(cell)
        cell.themedBackground = BoardTheme.brand
        cell.themedBackground = nil

        root.appearance = NSAppearance(named: .darkAqua)
        #expect(cell.layer?.backgroundColor == nil)
    }

    @Test("a view painting raw sublayers is re-themed through ThemeReapplying")
    func reapplyingAdoptersAreCalled() throws {
        let root = ThemedRootView()
        root.appearance = NSAppearance(named: .aqua)
        let gauge = GaugeSpy()
        root.addSubview(gauge)
        gauge.flips.removeAll()

        root.appearance = NSAppearance(named: .darkAqua)
        #expect(gauge.flips == [.darkAqua])

        root.appearance = NSAppearance(named: .aqua)
        #expect(gauge.flips == [.darkAqua, .aqua])
    }

    @Test("the gauge track is themed, not the hardcoded dark groove it used to be")
    func gaugeTrackIsThemed() throws {
        // It was `NSColor(white: 0.15)` — a near-black groove that stayed near-black on
        // cream paper. Both sides must differ, and the light one must read as a recess in
        // the panel rather than a hole punched through it.
        let dark = try resolved(BoardTheme.gaugeTrack, .darkAqua)
        let light = try resolved(BoardTheme.gaugeTrack, .aqua)
        #expect(dark != light)

        let lightTrack = try #require(NSColor(cgColor: light)?.usingColorSpace(.sRGB))
        #expect(lightTrack.brightnessComponent > 0.5, "a near-black groove on light paper again")
    }
}

/// Stands in for `QuotaBar`/`QuotaPlaceholderCell`, whose repaint targets are private
/// sublayers a test can't read. What's under test is the dispatch — that the appearance
/// walk calls adopters at all — which is exactly what those two rely on.
@MainActor
private final class GaugeSpy: NSView, ThemeReapplying {
    /// The appearance each repaint was handed — recorded, not just counted, because
    /// being called with the appearance we just *left* is the failure that bit here.
    var flips: [NSAppearance.Name] = []
    func reapplyTheme(under appearance: NSAppearance) { flips.append(appearance.name) }
}
