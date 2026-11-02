import CoreGraphics

/// Box-drawing (U+2500–U+257F) and block elements (U+2580–U+259F) drawn as
/// geometry that fills the whole cell, the way Ghostty and iTerm do it, instead of
/// font glyphs. A font's `─` never quite reaches the cell edges, so Claude Code's
/// input rules read as dashes and its block-art logo breaks apart; geometry joins
/// seamlessly across cells and rows.
enum BoxDrawing {

    /// Line weight of one arm: light or heavy. Double lines are left to the font.
    private enum Weight { case light, heavy }

    /// The arms a line character draws from the cell centre, clockwise.
    private struct Arms {
        var up: Weight?
        var right: Weight?
        var down: Weight?
        var left: Weight?
    }

    /// The filled path for `scalar` in `cell`, or `nil` when it is not a character
    /// this renderer draws (the caller falls back to the font). `light` is the light
    /// stroke width; heavy is twice that.
    static func path(for scalar: Unicode.Scalar, in cell: CGRect, light: CGFloat) -> CGPath? {
        if let quadrants = quadrants[scalar.value] {
            return blockPath(quadrants, in: cell)
        }
        if let corner = roundedCorners[scalar.value] {
            return roundedPath(corner, in: cell, width: light)
        }
        guard let arms = lineArms(scalar.value) else { return nil }
        return linePath(arms, in: cell, light: light)
    }

    // MARK: - Lines

    private static func lineArms(_ value: UInt32) -> Arms? {
        let l = Weight.light, h = Weight.heavy
        switch value {
        case 0x2500: return Arms(right: l, left: l)                 // ─
        case 0x2501: return Arms(right: h, left: h)                 // ━
        case 0x2502: return Arms(up: l, down: l)                    // │
        case 0x2503: return Arms(up: h, down: h)                    // ┃
        case 0x250C: return Arms(right: l, down: l)                 // ┌
        case 0x250F: return Arms(right: h, down: h)                 // ┏
        case 0x2510: return Arms(down: l, left: l)                  // ┐
        case 0x2513: return Arms(down: h, left: h)                  // ┓
        case 0x2514: return Arms(up: l, right: l)                   // └
        case 0x2517: return Arms(up: h, right: h)                   // ┗
        case 0x2518: return Arms(up: l, left: l)                    // ┘
        case 0x251B: return Arms(up: h, left: h)                    // ┛
        case 0x251C: return Arms(up: l, right: l, down: l)          // ├
        case 0x2523: return Arms(up: h, right: h, down: h)          // ┣
        case 0x2524: return Arms(up: l, down: l, left: l)           // ┤
        case 0x252B: return Arms(up: h, down: h, left: h)           // ┫
        case 0x252C: return Arms(right: l, down: l, left: l)        // ┬
        case 0x2533: return Arms(right: h, down: h, left: h)        // ┳
        case 0x2534: return Arms(up: l, right: l, left: l)          // ┴
        case 0x253B: return Arms(up: h, right: h, left: h)          // ┻
        case 0x253C: return Arms(up: l, right: l, down: l, left: l) // ┼
        case 0x254B: return Arms(up: h, right: h, down: h, left: h) // ╋
        case 0x2574: return Arms(left: l)                           // ╴
        case 0x2575: return Arms(up: l)                             // ╵
        case 0x2576: return Arms(right: l)                          // ╶
        case 0x2577: return Arms(down: l)                           // ╷
        case 0x2578: return Arms(left: h)                           // ╸
        case 0x2579: return Arms(up: h)                             // ╹
        case 0x257A: return Arms(right: h)                          // ╺
        case 0x257B: return Arms(down: h)                           // ╻
        default: return nil
        }
    }

    /// Each arm is a rect from the edge to just past the centre, so arms of any
    /// weight overlap into a solid joint. Horizontal arms overrun the cell by a
    /// hair: neighbouring cells sit at fractional x, and abutting anti-aliased
    /// edges would leave a faint seam in the rule.
    private static func linePath(_ arms: Arms, in cell: CGRect, light: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let overrun: CGFloat = 0.5
        func width(_ weight: Weight) -> CGFloat { weight == .heavy ? light * 2 : light }
        // The widest crossing arm, so a joint covers both strokes completely.
        let horizontal = max(arms.left.map(width) ?? 0, arms.right.map(width) ?? 0)
        let vertical = max(arms.up.map(width) ?? 0, arms.down.map(width) ?? 0)
        let midX = cell.midX, midY = cell.midY
        if let weight = arms.left {
            let w = width(weight)
            path.addRect(CGRect(x: cell.minX - overrun, y: midY - w / 2,
                                width: midX - cell.minX + overrun + vertical / 2, height: w))
        }
        if let weight = arms.right {
            let w = width(weight)
            let start = midX - vertical / 2
            path.addRect(CGRect(x: start, y: midY - w / 2,
                                width: cell.maxX - start + overrun, height: w))
        }
        if let weight = arms.up {
            let w = width(weight)
            path.addRect(CGRect(x: midX - w / 2, y: cell.minY,
                                width: w, height: midY - cell.minY + horizontal / 2))
        }
        if let weight = arms.down {
            let w = width(weight)
            let start = midY - horizontal / 2
            path.addRect(CGRect(x: midX - w / 2, y: start, width: w, height: cell.maxY - start))
        }
        return path
    }

    // MARK: - Rounded corners

    /// Which two edges a rounded corner joins, in a top-down (flipped) cell.
    private enum Corner { case downRight, downLeft, upLeft, upRight }

    private static let roundedCorners: [UInt32: Corner] = [
        0x256D: .downRight,   // ╭
        0x256E: .downLeft,    // ╮
        0x256F: .upLeft,      // ╯
        0x2570: .upRight,     // ╰
    ]

    /// A quarter curve from one edge midpoint to the other through the centre's
    /// control point, stroked into a fillable outline.
    private static func roundedPath(_ corner: Corner, in cell: CGRect, width: CGFloat) -> CGPath {
        let centre = CGPoint(x: cell.midX, y: cell.midY)
        let vertical = corner == .downRight || corner == .downLeft
            ? CGPoint(x: cell.midX, y: cell.maxY) : CGPoint(x: cell.midX, y: cell.minY)
        let horizontal = corner == .downRight || corner == .upRight
            ? CGPoint(x: cell.maxX + 0.5, y: cell.midY) : CGPoint(x: cell.minX - 0.5, y: cell.midY)
        let curve = CGMutablePath()
        curve.move(to: vertical)
        curve.addQuadCurve(to: horizontal, control: centre)
        return curve.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 1)
    }

    // MARK: - Blocks

    /// Quadrant bits for a top-down cell.
    private static let upperLeft: UInt8 = 1, upperRight: UInt8 = 2, lowerLeft: UInt8 = 4, lowerRight: UInt8 = 8

    private static let quadrants: [UInt32: UInt8] = [
        0x2580: upperLeft | upperRight,                             // ▀
        0x2584: lowerLeft | lowerRight,                             // ▄
        0x2588: upperLeft | upperRight | lowerLeft | lowerRight,    // █
        0x258C: upperLeft | lowerLeft,                              // ▌
        0x2590: upperRight | lowerRight,                            // ▐
        0x2596: lowerLeft,                                          // ▖
        0x2597: lowerRight,                                         // ▗
        0x2598: upperLeft,                                          // ▘
        0x2599: upperLeft | lowerLeft | lowerRight,                 // ▙
        0x259A: upperLeft | lowerRight,                             // ▚
        0x259B: upperLeft | upperRight | lowerLeft,                 // ▛
        0x259C: upperLeft | upperRight | lowerRight,                // ▜
        0x259D: upperRight,                                         // ▝
        0x259E: upperRight | lowerLeft,                             // ▞
        0x259F: upperRight | lowerLeft | lowerRight,                // ▟
    ]

    private static func blockPath(_ bits: UInt8, in cell: CGRect) -> CGPath {
        let path = CGMutablePath()
        let halfW = cell.width / 2, halfH = cell.height / 2
        let overrun: CGFloat = 0.5
        let quads: [(UInt8, CGRect)] = [
            (upperLeft, CGRect(x: cell.minX - overrun, y: cell.minY, width: halfW + overrun, height: halfH)),
            (upperRight, CGRect(x: cell.midX, y: cell.minY, width: halfW + overrun, height: halfH)),
            (lowerLeft, CGRect(x: cell.minX - overrun, y: cell.midY, width: halfW + overrun, height: halfH)),
            (lowerRight, CGRect(x: cell.midX, y: cell.midY, width: halfW + overrun, height: halfH)),
        ]
        for (bit, rect) in quads where bits & bit != 0 { path.addRect(rect) }
        return path
    }
}
