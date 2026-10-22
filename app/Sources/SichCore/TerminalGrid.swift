import GhosttyVt

/// A 24-bit RGB colour, the resolved cell colour libghostty-vt hands back (palette
/// indices already looked up). `nil` anywhere a colour is optional means "no
/// explicit colour — use the surface default".
public struct RGB: Hashable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// Visual attributes carried by the terminal's SGR state. Claude's TUI uses these
/// heavily for hierarchy even when it keeps the default foreground colour.
public struct TerminalCellStyle: Hashable, Sendable {
    public let bold: Bool
    public let italic: Bool
    public let faint: Bool
    public let inverse: Bool
    public let invisible: Bool
    public let strikethrough: Bool
    public let underline: Int

    public init(bold: Bool = false, italic: Bool = false, faint: Bool = false,
                inverse: Bool = false, invisible: Bool = false,
                strikethrough: Bool = false, underline: Int = 0) {
        self.bold = bold
        self.italic = italic
        self.faint = faint
        self.inverse = inverse
        self.invisible = invisible
        self.strikethrough = strikethrough
        self.underline = underline
    }

    public static let plain = TerminalCellStyle()
}

/// One rendered cell: a base character (nil = blank) plus its resolved fg/bg.
/// ponytail: base codepoint only — combining marks / ZWJ emoji sequences render as
/// their base glyph; carry the full grapheme buffer if a TUI ever needs it.
public struct TerminalCell: Hashable, Sendable {
    public let scalar: Unicode.Scalar?
    public let fg: RGB?
    public let bg: RGB?
    public let style: TerminalCellStyle
    public init(scalar: Unicode.Scalar?, fg: RGB?, bg: RGB?, style: TerminalCellStyle = .plain) {
        self.scalar = scalar; self.fg = fg; self.bg = bg; self.style = style
    }
    public static let blank = TerminalCell(scalar: nil, fg: nil, bg: nil)
}

/// The real cursor position in viewport cells (not a guessed end-of-text block).
public struct GridCursor: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let visible: Bool
    public init(x: Int, y: Int, visible: Bool) { self.x = x; self.y = y; self.visible = visible }
}

/// A full viewport snapshot: a `cols × rows` row-major grid of cells, the cursor,
/// whether the viewport sits on the live bottom, and the terminal's default
/// colours (fallback for cells with no explicit fg/bg). A value type so it crosses
/// to the AppKit surface without sharing the emulator.
public struct TerminalGrid: Equatable, Sendable {
    public let cols: Int
    public let rows: Int
    public let cells: [TerminalCell]   // row-major, exactly cols*rows
    public let cursor: GridCursor?
    /// The viewport is at the bottom of the scrollable area — the emulator's own
    /// scrollbar position, not "is the cursor on screen": a viewport scrolled less
    /// than a screen into history still shows most of the active area, and a TUI's
    /// repaint walks its cursor through exactly those rows.
    public let live: Bool
    public let defaultFg: RGB?
    public let defaultBg: RGB?

    public static let empty = TerminalGrid(cols: 0, rows: 0, cells: [], cursor: nil, live: true,
                                           defaultFg: nil, defaultBg: nil)

    public func cell(col: Int, row: Int) -> TerminalCell {
        let i = row * cols + col
        return cells.indices.contains(i) ? cells[i] : .blank
    }
}

/// A reusable libghostty-vt render-state reader. Allocates the state + row iterator
/// + cells containers ONCE (the C API is built for reuse — see render.h) and frees
/// them on deinit; ``snapshot(from:)`` repopulates and walks them each frame to
/// produce a colour-aware ``TerminalGrid``. This is the colour/cursor path the
/// plain-text formatter (`Terminal.lines()`) can't give.
final class RenderState {
    private let state: GhosttyRenderState
    private let iter: GhosttyRenderStateRowIterator
    private let rowCells: GhosttyRenderStateRowCells

    init() throws {
        var st: GhosttyRenderState?
        let r1 = ghostty_render_state_new(nil, &st)
        guard r1 == GHOSTTY_SUCCESS, let st else {
            throw TerminalError(op: "ghostty_render_state_new", code: r1.rawValue)
        }
        var it: GhosttyRenderStateRowIterator?
        let r2 = ghostty_render_state_row_iterator_new(nil, &it)
        guard r2 == GHOSTTY_SUCCESS, let it else {
            ghostty_render_state_free(st)
            throw TerminalError(op: "ghostty_render_state_row_iterator_new", code: r2.rawValue)
        }
        var rc: GhosttyRenderStateRowCells?
        let r3 = ghostty_render_state_row_cells_new(nil, &rc)
        guard r3 == GHOSTTY_SUCCESS, let rc else {
            ghostty_render_state_row_iterator_free(it)
            ghostty_render_state_free(st)
            throw TerminalError(op: "ghostty_render_state_row_cells_new", code: r3.rawValue)
        }
        self.state = st
        self.iter = it
        self.rowCells = rc
    }

    deinit {
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(iter)
        ghostty_render_state_free(state)
    }

    /// Read the terminal's current viewport into a value-type grid. Returns
    /// ``TerminalGrid/empty`` if the state could not be updated (caller keeps its
    /// last good grid rather than blanking the screen).
    func snapshot(from terminal: GhosttyTerminal) -> TerminalGrid {
        guard ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS else { return .empty }
        let cols = Int(u16(GHOSTTY_RENDER_STATE_DATA_COLS))
        let rows = Int(u16(GHOSTTY_RENDER_STATE_DATA_ROWS))
        guard cols > 0, rows > 0 else { return .empty }

        var cells: [TerminalCell] = []
        cells.reserveCapacity(cols * rows)
        populateIterator()
        var produced = 0
        while produced < rows, ghostty_render_state_row_iterator_next(iter) {
            cells.append(contentsOf: readRow(cols: cols))
            produced += 1
        }
        // Pad any short tail so the rectangle (and cell(col:row:) math) always holds.
        while produced < rows {
            cells.append(contentsOf: Array(repeating: .blank, count: cols))
            produced += 1
        }
        return TerminalGrid(cols: cols, rows: rows, cells: cells,
                            cursor: readCursor(),
                            live: viewportIsLive(terminal),
                            defaultFg: defaultColor(GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND),
                            defaultBg: defaultColor(GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND))
    }

    // MARK: - Row / cell walk

    private func populateIterator() {
        var it: GhosttyRenderStateRowIterator? = iter   // populate our pre-allocated iterator
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)
    }

    private func readRow(cols: Int) -> [TerminalCell] {
        var rc: GhosttyRenderStateRowCells? = rowCells
        guard ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rc) == GHOSTTY_SUCCESS else {
            return Array(repeating: .blank, count: cols)
        }
        var out: [TerminalCell] = []
        out.reserveCapacity(cols)
        while out.count < cols, ghostty_render_state_row_cells_next(rowCells) {
            out.append(readCell())
        }
        while out.count < cols { out.append(.blank) }
        return out
    }

    private func readCell() -> TerminalCell {
        TerminalCell(scalar: cellScalar(),
                     fg: cellColor(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR),
                     bg: cellColor(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR),
                     style: cellStyle())
    }

    private func cellStyle() -> TerminalCellStyle {
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        guard ghostty_render_state_row_cells_get(
            rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS
        else { return .plain }
        return TerminalCellStyle(
            bold: style.bold, italic: style.italic, faint: style.faint,
            inverse: style.inverse, invisible: style.invisible,
            strikethrough: style.strikethrough, underline: Int(style.underline))
    }

    private func cellScalar() -> Unicode.Scalar? {
        var len: UInt32 = 0
        _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)
        guard len > 0 else { return nil }
        // The overwhelmingly common case is one scalar. Avoid allocating a Swift
        // array for every ordinary terminal cell on every snapshot.
        if len == 1 {
            var cp: UInt32 = 0
            _ = ghostty_render_state_row_cells_get(
                rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &cp)
            return Unicode.Scalar(cp)
        }
        var cps = [UInt32](repeating: 0, count: Int(len))
        cps.withUnsafeMutableBufferPointer { buf in
            _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buf.baseAddress)
        }
        return Unicode.Scalar(cps[0])   // base codepoint
    }

    private func cellColor(_ which: GhosttyRenderStateRowCellsData) -> RGB? {
        var c = GhosttyColorRgb()
        // INVALID_VALUE = "no explicit colour" → nil, caller uses its default.
        guard ghostty_render_state_row_cells_get(rowCells, which, &c) == GHOSTTY_SUCCESS else { return nil }
        return RGB(r: c.r, g: c.g, b: c.b)
    }

    // MARK: - Cursor + viewport + scalar reads

    /// Bottom of the scrollable area ⇔ the live screen. Read from the terminal's
    /// scrollbar (offset + visible length against the total), which is exact for a
    /// viewport parked on an arbitrary history pin.
    private func viewportIsLive(_ terminal: GhosttyTerminal) -> Bool {
        var bar = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar) == GHOSTTY_SUCCESS
        else { return true }
        return bar.offset + bar.len >= bar.total
    }

    private func readCursor() -> GridCursor? {
        guard boolValue(GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE) else { return nil }
        return GridCursor(x: Int(u16(GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X)),
                          y: Int(u16(GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y)),
                          visible: boolValue(GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE))
    }

    private func u16(_ data: GhosttyRenderStateData) -> UInt16 {
        var v: UInt16 = 0
        _ = ghostty_render_state_get(state, data, &v)
        return v
    }

    private func boolValue(_ data: GhosttyRenderStateData) -> Bool {
        var v = false
        _ = ghostty_render_state_get(state, data, &v)
        return v
    }

    private func defaultColor(_ data: GhosttyRenderStateData) -> RGB? {
        var c = GhosttyColorRgb()
        guard ghostty_render_state_get(state, data, &c) == GHOSTTY_SUCCESS else { return nil }
        return RGB(r: c.r, g: c.g, b: c.b)
    }
}
