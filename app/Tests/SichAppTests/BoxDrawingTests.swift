import CoreGraphics
import Testing

@testable import SichApp

/// Line and block characters are drawn as cell-filling geometry so Claude Code's
/// `────` rules read as one line and its block-art logo stays solid.
@Suite("Box-drawing characters fill their cell")
struct BoxDrawingTests {

    private let cell = CGRect(x: 0, y: 0, width: 12, height: 24)

    private func path(_ scalar: Unicode.Scalar) -> CGPath? {
        BoxDrawing.path(for: scalar, in: cell, light: 1)
    }

    @Test("a horizontal rule reaches both cell edges, so adjacent cells join seamlessly")
    func horizontalRuleSpansTheCell() throws {
        let rule = try #require(path("─"))
        #expect(rule.contains(CGPoint(x: 0.1, y: 12)))
        #expect(rule.contains(CGPoint(x: 11.9, y: 12)))
        #expect(!rule.contains(CGPoint(x: 6, y: 2)))
        #expect(!rule.contains(CGPoint(x: 6, y: 22)))
    }

    @Test("a vertical line reaches the top and bottom, so rows join seamlessly")
    func verticalLineSpansTheRow() throws {
        let line = try #require(path("│"))
        #expect(line.contains(CGPoint(x: 6, y: 0.1)))
        #expect(line.contains(CGPoint(x: 6, y: 23.9)))
        #expect(!line.contains(CGPoint(x: 1, y: 12)))
    }

    @Test("a corner draws only its two arms")
    func cornerDrawsTwoArms() throws {
        let corner = try #require(path("┌"))
        #expect(corner.contains(CGPoint(x: 11.9, y: 12)))   // right arm
        #expect(corner.contains(CGPoint(x: 6, y: 23.9)))    // down arm
        #expect(!corner.contains(CGPoint(x: 0.5, y: 12)))   // no left arm
        #expect(!corner.contains(CGPoint(x: 6, y: 0.5)))    // no up arm
    }

    @Test("a rounded corner meets the same edge midpoints as a square one")
    func roundedCornerMeetsEdges() throws {
        let corner = try #require(path("╭"))
        #expect(corner.contains(CGPoint(x: 11.9, y: 12)))
        #expect(corner.contains(CGPoint(x: 6, y: 23.9)))
        #expect(!corner.contains(CGPoint(x: 1, y: 1)))
    }

    @Test("block quadrants fill exactly their quarters")
    func quadrantsFillTheirQuarters() throws {
        let full = try #require(path("█"))
        for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 11.5, y: 23.5)] {
            #expect(full.contains(point))
        }
        let threeQuarters = try #require(path("▛"))
        #expect(threeQuarters.contains(CGPoint(x: 3, y: 6)))
        #expect(threeQuarters.contains(CGPoint(x: 9, y: 6)))
        #expect(threeQuarters.contains(CGPoint(x: 3, y: 18)))
        #expect(!threeQuarters.contains(CGPoint(x: 9, y: 18)))
    }

    @Test("ordinary text is left to the font")
    func textFallsBackToTheFont() {
        #expect(path("a") == nil)
        #expect(path("⏺") == nil)
        #expect(path("═") == nil)
    }
}
