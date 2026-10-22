import AppKit
@testable import SichCore
import Testing

@testable import SichApp

/// The 120 Hz scroll path: the viewport is one `CALayer` per row showing a
/// content-keyed cached image, so a scroll re-uses every row that was already on
/// screen and only renders the rows that are genuinely new. These tests pin the
/// cache accounting and the layer stack the surface drives, and the surface wiring
/// itself (a shifted grid = hits, not repaints).
@MainActor
@Suite("Terminal rows are cached images on per-row layers")
struct TerminalRowLayerTests {

    private func row(_ text: String, cols: Int) -> [TerminalCell] {
        let scalars = Array(text.unicodeScalars)
        return (0..<cols).map { col in
            col < scalars.count ? TerminalCell(scalar: scalars[col], fg: nil, bg: nil) : .blank
        }
    }

    private func grid(_ lines: [String], cols: Int = 12) -> TerminalGrid {
        TerminalGrid(cols: cols, rows: lines.count, cells: lines.flatMap { row($0, cols: cols) },
                     cursor: nil, live: true, defaultFg: nil, defaultBg: nil)
    }

    private func key(_ text: String) -> TerminalRowKey {
        TerminalRowKey(cells: row(text, cols: 12), scale: 2)
    }

    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        return ctx.makeImage()!
    }

    // MARK: - Cache

    @Test("the same row content is rendered once and then served from the cache")
    func sameContentIsAHit() {
        let cache = TerminalRowCache()
        var renders = 0
        cache.beginFrame()
        _ = cache.image(for: key("alpha")) { _ in renders += 1; return makeImage() }
        cache.beginFrame()
        _ = cache.image(for: key("alpha")) { _ in renders += 1; return makeImage() }
        #expect(renders == 1)
        #expect(cache.hits == 1)
        #expect(cache.misses == 1)
    }

    @Test("a blank render (nil) is not cached and counts as neither hit nor miss")
    func nilRenderIsNotStored() {
        let cache = TerminalRowCache()
        cache.beginFrame()
        #expect(cache.image(for: key("")) { _ in nil } == nil)
        #expect(cache.count == 0)
    }

    @Test("under capacity, rows that scrolled off stay warm; over it, only this frame's rows survive")
    func trimKeepsOnlyCurrentFrameOnceOverCapacity() {
        let cache = TerminalRowCache()
        cache.beginFrame()
        for text in ["a", "b", "c"] { _ = cache.image(for: key(text)) { _ in makeImage() } }
        cache.beginFrame()
        _ = cache.image(for: key("d")) { _ in makeImage() }

        cache.trim(capacity: 10)
        #expect(cache.count == 4)            // below the cap nothing is dropped

        cache.trim(capacity: 2)
        #expect(cache.count == 1)            // only "d" was used this frame
        cache.beginFrame()
        _ = cache.image(for: key("d")) { _ in Issue.record("d was trimmed"); return nil }
        _ = cache.image(for: key("a")) { _ in makeImage() }
        #expect(cache.misses == 5)
    }

    // MARK: - Layer host

    @Test("the host keeps exactly one layer per row, stacked from its top edge, and hides blank rows")
    func hostLaysOutOneLayerPerRow() {
        let host = TerminalRowLayerHost(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        host.layout(rowCount: 3, rowSize: CGSize(width: 120, height: 20), scale: 2)
        #expect(host.rowCount == 3)
        let layers = host.layer!.sublayers!
        #expect(layers.count == 3)
        #expect(layers[2].frame == CGRect(x: 0, y: 40, width: 120, height: 20))
        #expect(layers[2].contentsScale == 2)

        let image = makeImage()
        host.show(image, atRow: 1)
        host.show(nil, atRow: 2)
        #expect(layers[1].isHidden == false)
        #expect(layers[1].contents != nil)
        #expect(layers[2].isHidden)

        host.layout(rowCount: 1, rowSize: CGSize(width: 120, height: 20), scale: 2)
        #expect(host.rowCount == 1)
        #expect(host.layer!.sublayers!.count == 1)
    }

    @Test("a sub-row offset shifts the clip's bounds up and clips at its edges")
    func scrollOffsetMovesTheBoundsNotTheRows() {
        let host = TerminalRowLayerHost(frame: NSRect(x: 9, y: 9, width: 120, height: 60))
        host.layout(rowCount: 4, rowSize: CGSize(width: 120, height: 20), scale: 2)
        host.setScrollOffset(7)
        #expect(host.bounds.origin == NSPoint(x: 0, y: 7))
        #expect(host.layer!.sublayers![3].frame.origin.y == 60)   // the spare row stays put
        #expect(host.layer!.masksToBounds)
    }

    @Test("row layers never run implicit animations and never take mouse events")
    func rowLayersAreInertForAnimationAndHitTesting() {
        let host = TerminalRowLayerHost(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        host.layout(rowCount: 1, rowSize: CGSize(width: 120, height: 20), scale: 2)
        let row = host.layer!.sublayers![0]
        #expect(row.action(forKey: "contents") == nil)
        #expect(row.action(forKey: "hidden") == nil)
        #expect(host.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    // MARK: - Surface wiring

    private func makeSurface() throws -> (TerminalSurface, PTYSession) {
        let session = try PTYSession(command: ["/bin/cat"])
        try session.start()
        let surface = TerminalSurface(session: session)
        surface.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        return (surface, session)
    }

    @Test("a viewport shifted by one row re-uses every row already on screen and renders only the new one")
    func scrollingOneRowIsAllHitsButOne() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        surface.installGridForTesting(grid(["one", "two", "three", ""]))
        let cache = surface.rowCacheForTesting
        #expect(cache.misses == 3)           // three text rows rendered, the blank row skipped
        #expect(surface.rowHostForTesting.rowCount == 5)   // four rows + the spare row below
        #expect(surface.rowHostForTesting.layer!.sublayers![3].isHidden)
        #expect(surface.rowHostForTesting.layer!.sublayers![4].isHidden)
        #expect(surface.rowHostForTesting.frame.origin == NSPoint(x: 9, y: 9))

        surface.installGridForTesting(grid(["two", "three", "four", ""]))
        #expect(cache.hits == 2)             // "two" and "three" moved up, not repainted
        #expect(cache.misses == 4)           // only "four" was new
    }

    @Test("an appearance change throws the painted rows away so the new palette is applied")
    func appearanceChangeClearsTheCache() throws {
        let (surface, session) = try makeSurface()
        defer { session.terminate() }
        surface.installGridForTesting(grid(["one", "two"]))
        #expect(surface.rowCacheForTesting.count == 2)
        surface.viewDidChangeEffectiveAppearance()
        #expect(surface.rowCacheForTesting.count == 0)
    }
}
