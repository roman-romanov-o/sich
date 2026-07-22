import AppKit
import Testing

@testable import GhostlingApp

/// "I use a laptop screen and cannot fit the window": the resize floor is the only
/// thing that can make the window impossible to fit — the board itself is flexible
/// (equal-width columns, truncating card text). Guard the floor against creeping
/// back above a built-in laptop display.
@MainActor
@Suite("Board window fits a laptop screen")
struct WindowMinSizeTests {

    /// The smallest common built-in target: a 13" MacBook Air at its default
    /// scaled resolution is 1280×832 points, minus the menu bar (~25pt).
    @Test("min content size stays within a 1280×832 laptop visible frame")
    func minSizeFitsLaptopScreen() {
        let laptopVisible = NSSize(width: 1280, height: 807)
        #expect(BoardShell.minContentSize.width <= laptopVisible.width)
        #expect(BoardShell.minContentSize.height <= laptopVisible.height)
    }

    @Test("resize floor permits a compact window")
    func resizeFloorIsCompact() {
        #expect(BoardShell.minContentSize == NSSize(width: 640, height: 420))
    }

    @Test("oversized window is shrunk and repositioned into the visible frame")
    func oversizedFrameIsFitted() {
        let visible = NSRect(x: 0, y: 25, width: 1280, height: 807)
        let oversized = NSRect(x: -140, y: -80, width: 1600, height: 1000)

        #expect(BoardShell.fittedFrame(oversized, inside: visible) == visible)
    }

    @Test("an already fitting user-sized window is not enlarged")
    func fittingFrameIsPreserved() {
        let visible = NSRect(x: 100, y: 40, width: 1280, height: 807)
        let userFrame = NSRect(x: 220, y: 160, width: 900, height: 600)

        #expect(BoardShell.fittedFrame(userFrame, inside: visible) == userFrame)
    }
}
