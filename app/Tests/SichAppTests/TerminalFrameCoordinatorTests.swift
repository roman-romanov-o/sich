import CoreGraphics
import Testing
@testable import SichApp

@Suite("Terminal frame scheduling")
struct TerminalFrameCoordinatorTests {
    @Test("refresh requests coalesce to the strongest damage reason")
    func refreshReasonCoalescing() {
        var queue = TerminalRefreshQueue()

        queue.request(.output)
        queue.request(.viewport)
        queue.request(.output)

        #expect(queue.consume() == .viewport)
        #expect(queue.consume() == nil)

        queue.request(.output)
        queue.request(.full)
        queue.request(.viewport)
        #expect(queue.consume() == .full)
    }

    /// A wheel event normalized to rows, then quantized — the path the child-owned
    /// wheel (mouse reports, alternate-screen arrows) takes.
    private func rows(_ accumulator: inout TerminalScrollAccumulator,
                      deltaY: CGFloat, precise: Bool, cellHeight: CGFloat) -> Int {
        accumulator.rows(adding: TerminalScrollAccumulator.rowDelta(
            deltaY: deltaY, precise: precise, cellHeight: cellHeight))
    }

    @Test("precise trackpad pixels use Ghostty sensitivity and retain residue")
    func preciseScrollAccumulation() {
        var accumulator = TerminalScrollAccumulator()

        #expect(rows(&accumulator, deltaY: 4, precise: true, cellHeight: 20) == 0)
        #expect(accumulator.residue == 0.4)
        #expect(rows(&accumulator, deltaY: 6, precise: true, cellHeight: 20) == 1)
        #expect(abs(accumulator.residue) < 0.000_001)
    }

    @Test("opposite precise motion cancels pending movement")
    func preciseDirectionChange() {
        var accumulator = TerminalScrollAccumulator()

        #expect(rows(&accumulator, deltaY: 7, precise: true, cellHeight: 20) == 0)
        #expect(rows(&accumulator, deltaY: -4, precise: true, cellHeight: 20) == 0)
        #expect(abs(accumulator.residue - 0.3) < 0.000_001)
        #expect(rows(&accumulator, deltaY: -8, precise: true, cellHeight: 20) == 0)
        #expect(abs(accumulator.residue + 0.5) < 0.000_001)
    }

    @Test("discrete mouse-wheel deltas remain rows and retain fractions")
    func discreteScrollAccumulation() {
        var accumulator = TerminalScrollAccumulator()

        #expect(rows(&accumulator, deltaY: 0.5, precise: false, cellHeight: 99) == 0)
        #expect(rows(&accumulator, deltaY: 0.75, precise: false, cellHeight: 99) == 1)
        #expect(abs(accumulator.residue - 0.25) < 0.000_001)
    }
}
