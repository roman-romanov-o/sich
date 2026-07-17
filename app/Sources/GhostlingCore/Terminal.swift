import GhosttyVt

/// Thrown when a libghostty-vt C call returns a non-success result.
public struct TerminalError: Error, CustomStringConvertible {
    public let op: String
    public let code: Int32
    public var description: String { "libghostty-vt \(op) failed (code \(code))" }
}

/// A safe Swift wrapper over a libghostty-vt terminal emulator instance.
///
/// Owns the underlying `GhosttyTerminal` handle and frees it on `deinit`. Bytes
/// produced by a child process are fed in with ``write(_:)``; the rendered screen
/// is read back with ``plainText()`` — no screen-scraping, the same in-process
/// path proven by the Phase 00 spike.
public final class Terminal {
    private let handle: GhosttyTerminal

    public init(cols: UInt16 = 80, rows: UInt16 = 24, maxScrollback: Int = 1000) throws {
        var handle: GhosttyTerminal?
        let opts = GhosttyTerminalOptions(cols: cols, rows: rows, max_scrollback: maxScrollback)
        let r = ghostty_terminal_new(nil, &handle, opts)
        guard r == GHOSTTY_SUCCESS, let handle else {
            throw TerminalError(op: "ghostty_terminal_new", code: r.rawValue)
        }
        self.handle = handle
    }

    deinit {
        ghostty_mouse_encoder_free(mouseEncoderStorage)
        ghostty_terminal_free(handle)
    }

    // MARK: - Colour theme

    /// Push a colour theme into the emulator: default fg/bg/cursor plus the 256-entry
    /// palette that ANSI colour indices resolve through.
    ///
    /// Safe to call at any time — libghostty resolves a cell's palette index when the
    /// render state is *read*, so re-applying on a light/dark flip re-colours existing
    /// scrollback rather than only new output. Per-index OSC 4 overrides a program set
    /// for itself are preserved; only untouched indices are updated.
    public func apply(theme: TerminalTheme) {
        setColor(GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, theme.background)
        setColor(GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, theme.foreground)
        setColor(GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, theme.cursor)
        let entries = theme.palette.map { GhosttyColorRgb(r: $0.r, g: $0.g, b: $0.b) }
        entries.withUnsafeBufferPointer {
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress)
        }
    }

    private func setColor(_ option: GhosttyTerminalOption, _ rgb: RGB) {
        var c = GhosttyColorRgb(r: rgb.r, g: rgb.g, b: rgb.b)
        _ = ghostty_terminal_set(handle, option, &c)
    }

    /// The emulator's live 256-entry palette (including any OSC 4 overrides a program
    /// applied). Empty only if the read fails. The read-back that proves a theme
    /// actually landed in libghostty rather than just being held in Swift.
    public func currentPalette() -> [RGB] {
        var entries = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        let r = entries.withUnsafeMutableBufferPointer {
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, $0.baseAddress)
        }
        guard r == GHOSTTY_SUCCESS else { return [] }
        return entries.map { RGB(r: $0.r, g: $0.g, b: $0.b) }
    }

    /// Feed raw output bytes (including VT escape sequences) into the emulator.
    public func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buf in
            ghostty_terminal_vt_write(handle, buf.baseAddress, buf.count)
        }
    }

    /// Resize the emulator grid (reflows the primary screen when wraparound is on)
    /// and update its pixel dimensions. Pair with the pty's `TIOCSWINSZ` so the
    /// child and the emulator agree on geometry — the fix for a child stuck at 80×24.
    public func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) {
        ghostty_terminal_resize(handle, cols, rows, cellWidthPx, cellHeightPx)
    }

    /// A colour-aware viewport snapshot (resolved fg/bg per cell + the real cursor),
    /// the render path `TerminalSurface` draws. Lazily creates the render state;
    /// returns ``TerminalGrid/empty`` if it could not be created.
    public func snapshot() -> TerminalGrid {
        renderState?.snapshot(from: handle) ?? .empty
    }

    private lazy var renderState: RenderState? = try? RenderState()

    /// Scroll the viewport by `delta` rows (negative = up into scrollback).
    /// The next ``snapshot()`` reflects the scrolled viewport.
    public func scrollViewport(delta: Int) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = delta
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    /// Snap the viewport back to the live bottom (the active screen).
    public func scrollViewportToBottom() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    /// Whether the child has enabled bracketed paste (DEC mode 2004) — the paste
    /// path wraps the payload in `ESC[200~` / `ESC[201~` when set, so multi-line
    /// pastes reach a TUI (Claude Code, vim) as one paste, not typed keystrokes.
    public var bracketedPasteEnabled: Bool {
        // GHOSTTY_MODE_BRACKETED_PASTE is a function-like C macro Swift can't
        // import; expand it: DEC private mode 2004.
        modeSet(2004)
    }

    /// Whether the child is on the alternate screen (DEC 1047/1049 — full-screen
    /// TUIs like vim or less). There is no scrollback on the alternate screen, so
    /// the wheel should fall back to arrow keys instead of moving the viewport.
    public var alternateScreenActive: Bool {
        modeSet(1047) || modeSet(1049)
    }

    private func modeSet(_ mode: UInt16) -> Bool {
        var value = false
        let r = ghostty_terminal_mode_get(handle, ghostty_mode_new(mode, false), &value)
        return r == GHOSTTY_SUCCESS && value
    }

    // MARK: - Mouse reporting

    /// Pixel geometry the mouse encoder needs to map surface points onto cells.
    public struct MouseGeometry {
        public let screenWidth: UInt32
        public let screenHeight: UInt32
        public let cellWidth: UInt32
        public let cellHeight: UInt32
        public let padding: UInt32

        public init(screenWidth: UInt32, screenHeight: UInt32,
                    cellWidth: UInt32, cellHeight: UInt32, padding: UInt32) {
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
            self.cellWidth = cellWidth
            self.cellHeight = cellHeight
            self.padding = padding
        }
    }

    /// Encode one wheel tick as the mouse report the child asked for, or `nil`
    /// when the child has no mouse tracking enabled — the caller then scrolls the
    /// viewport itself. This is how a TUI that owns its own scrolling (Claude
    /// Code's chat pane, vim with mouse=a) actually receives the wheel.
    public func encodeWheel(up: Bool, x: Float, y: Float, geometry: MouseGeometry) -> [UInt8]? {
        guard let encoder = mouseEncoder() else { return nil }
        ghostty_mouse_encoder_setopt_from_terminal(encoder, handle)
        var size = GhosttyMouseEncoderSize(
            size: MemoryLayout<GhosttyMouseEncoderSize>.size,
            screen_width: geometry.screenWidth, screen_height: geometry.screenHeight,
            cell_width: geometry.cellWidth, cell_height: geometry.cellHeight,
            padding_top: geometry.padding, padding_bottom: geometry.padding,
            padding_right: geometry.padding, padding_left: geometry.padding)
        withUnsafePointer(to: &size) {
            ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, $0)
        }
        return encodeWheelEvent(encoder: encoder, up: up, x: x, y: y)
    }

    private func encodeWheelEvent(
        encoder: GhosttyMouseEncoder, up: Bool, x: Float, y: Float
    ) -> [UInt8]? {
        var event: GhosttyMouseEvent?
        guard ghostty_mouse_event_new(nil, &event) == GHOSTTY_SUCCESS, let event else {
            return nil
        }
        defer { ghostty_mouse_event_free(event) }
        ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS)
        ghostty_mouse_event_set_button(
            event, up ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE)
        ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: x, y: y))

        var buf = [CChar](repeating: 0, count: 64)
        var written = 0
        let r = buf.withUnsafeMutableBufferPointer {
            ghostty_mouse_encoder_encode(encoder, event, $0.baseAddress, $0.count, &written)
        }
        // written == 0 is the "tracking off" signal: nothing to send the child.
        guard r == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return buf[0..<written].map { UInt8(bitPattern: $0) }
    }

    private var mouseEncoderStorage: GhosttyMouseEncoder?

    private func mouseEncoder() -> GhosttyMouseEncoder? {
        if let encoder = mouseEncoderStorage { return encoder }
        var encoder: GhosttyMouseEncoder?
        guard ghostty_mouse_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS else { return nil }
        mouseEncoderStorage = encoder
        return encoder
    }

    /// Render the active screen as trimmed plain text.
    public func plainText() throws -> String {
        let formatter = try makePlainFormatter()
        defer { ghostty_formatter_free(formatter) }
        return try formatString(from: formatter)
    }

    /// The active screen split into renderable lines, top to bottom.
    ///
    /// This is the window-free extraction `TerminalSurface` draws and that
    /// `swift test` can assert against a known feed — no AppKit involved.
    public func lines() throws -> [String] {
        let text = try plainText()
        if text.isEmpty { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Private helpers

    private func makePlainFormatter() throws -> GhosttyFormatter {
        // GHOSTTY_INIT_SIZED is a C macro unavailable to Swift, so set `.size` by hand.
        var opts = GhosttyFormatterTerminalOptions()
        opts.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.trim = true

        var formatter: GhosttyFormatter?
        let r = ghostty_formatter_terminal_new(nil, &formatter, handle, opts)
        guard r == GHOSTTY_SUCCESS, let formatter else {
            throw TerminalError(op: "ghostty_formatter_terminal_new", code: r.rawValue)
        }
        return formatter
    }

    private func formatString(from formatter: GhosttyFormatter) throws -> String {
        var buf: UnsafeMutablePointer<UInt8>?
        var len = 0
        let r = ghostty_formatter_format_alloc(formatter, nil, &buf, &len)
        guard r == GHOSTTY_SUCCESS, let buf else {
            throw TerminalError(op: "ghostty_formatter_format_alloc", code: r.rawValue)
        }
        defer { ghostty_free(nil, buf, len) }
        return String(decoding: UnsafeBufferPointer(start: buf, count: len), as: UTF8.self)
    }
}
