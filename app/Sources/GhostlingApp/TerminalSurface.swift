import AppKit
import GhostlingCore

/// A thin AppKit view that renders one ``PTYSession``'s libghostty-vt screen and
/// routes key events back into it. Single responsibility: one surface = one PTY.
/// There is **no** product logic here (no board, no quota) — it only renders the
/// emulator grid and forwards keystrokes, leaning on `Terminal`/`PTYSession`.
///
/// Rendering is a per-cell colour draw of `Terminal.snapshot()` — resolved fg/bg
/// runs plus the emulator's real cursor — and the surface drives a live `TIOCSWINSZ`
/// resize so the child reflows to the window instead of staying at 80×24.
@MainActor
public final class TerminalSurface: NSView {
    private let session: PTYSession
    private var readTimer: Timer?
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let inset: CGFloat = 6
    /// Back policy. When set, `⌘[` (the macOS "Back" idiom) is offered here; returning
    /// `true` means "this surface is hosted (e.g. drilled-in)" so the combo is consumed
    /// as a leave-to-board, NOT sent to the child. `nil` / `false` ⇒ no host, nothing
    /// special happens.
    ///
    /// `Esc` is deliberately NOT used: an interactive agent in the child (Claude Code's
    /// `Esc` to interrupt, `Esc Esc` to edit) needs it, so plain Esc always flows to the
    /// PTY. `⌘`-combos never reach a terminal child, so they're collision-free — and the
    /// right seam for them is `performKeyEquivalent`, not `keyDown`.
    var onBack: (() -> Bool)?
    /// The last rendered viewport (resolved cells + cursor); refreshed on PTY output.
    private var grid: TerminalGrid = .empty
    /// A dim end-of-session banner appended once the session terminates, so a
    /// finished window reads as *ended* rather than *hung*. `nil` while live.
    private var endBanner: String?

    /// One monospaced cell's exact advance × line height. Kept fractional (not
    /// rounded) so a coalesced glyph run drawn as one string stays grid-aligned:
    /// the font advances by exactly this width per char, matching `col * cellSize`.
    private lazy var cellSize: CGSize = {
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        let h = font.ascender - font.descender + font.leading
        return CGSize(width: w, height: h)
    }()

    public init(session: PTYSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = BoardTheme.termBg.cgColor
        // Clip drawing to our own bounds. Without this, a flipped, layer-backed
        // surface composites its black fill across the WHOLE host window (the dirty
        // rect it is handed spans the host, and an unclipped layer paints all of it),
        // burying the drill-in's header strip + "← board" pill behind a full-window
        // black rectangle even though the header's geometry is correct (hit-testing
        // still resolves to the pill — clicks worked while the chrome was invisible).
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    // MARK: - Geometry → live resize

    /// Recompute the cols×rows that fit the current bounds and push them to the
    /// session (pty `TIOCSWINSZ` + emulator). `session.resize` is a no-op when the
    /// geometry is unchanged, so calling this on every layout pass is cheap. The
    /// fix for the "barely usable, bad in terms of window" complaint: the child now
    /// sees the real window size and reflows to it.
    private func syncTerminalSize() {
        guard cellSize.width > 0, cellSize.height > 0,
              bounds.width > 2 * inset, bounds.height > 2 * inset else { return }
        let cols = max(1, Int((bounds.width - 2 * inset) / cellSize.width))
        let rows = max(1, Int((bounds.height - 2 * inset) / cellSize.height))
        session.resize(rows: UInt16(rows), cols: UInt16(cols),
                       cellWidthPx: UInt32(cellSize.width.rounded()),
                       cellHeightPx: UInt32(cellSize.height.rounded()))
        refresh()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncTerminalSize()
    }

    // MARK: - PTY read loop

    /// Start reading the PTY on the main run loop so the emulator screen stays
    /// live without screen-scraping. Idempotent.
    ///
    /// Driven by a run-loop `Timer` on a non-blocking fd, NOT a `.main`-queue
    /// `DispatchSourceRead`: a `.main` dispatch source only fires when the main
    /// *dispatch queue* is drained, which a plain run-loop (the spun-loop tests, and
    /// some AppKit nesting) does not do — so the surface rendered nothing and the
    /// terminal "didn't open." A `Timer` in `.common` modes fires identically under
    /// `NSApp.run()` and a spun loop, on the main thread, with no cross-thread vt
    /// access. ponytail: 30Hz poll of a non-blocking fd — swap for a kqueue source
    /// only if idle wakeups ever show up in a power profile.
    public func startReading() {
        guard readTimer == nil, session.masterFD >= 0 else { return }
        session.setNonBlocking()
        syncTerminalSize()   // match the child to the window before the first paint
        scheduleTimer(hz: Self.activeHz)
        onTick()   // paint whatever is already buffered without waiting a frame
    }

    public func stopReading() {
        readTimer?.invalidate()
        readTimer = nil
    }

    // Adaptive cadence: 30Hz while output flows, 4Hz once the child has been
    // quiet for ~1s — the shell-at-its-prompt case that otherwise burns battery.
    // First byte after idle upshifts immediately (worst added latency: 250ms).
    private static let activeHz = 30.0
    private static let idleHz = 4.0
    private static let idleTickThreshold = 30   // ~1s of silence at 30Hz
    private var idleTicks = 0

    private func scheduleTimer(hz: Double) {
        readTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        readTimer = timer
    }

    private func onTick() {
        switch session.pumpAvailable() {
        case .data:
            if idleTicks >= Self.idleTickThreshold { scheduleTimer(hz: Self.activeHz) }
            idleTicks = 0
            refresh()
        case .idle:
            idleTicks += 1
            if idleTicks == Self.idleTickThreshold { scheduleTimer(hz: Self.idleHz) }
        case .eof:
            stopReading()                // child gone
        }
    }

    private func refresh() {
        let snap = session.terminal.snapshot()
        guard snap.rows > 0 else { return }   // never blank a good screen on a failed read
        let old = grid
        grid = snap
        // Damage-diff: invalidate only the rows that actually changed (plus the
        // cursor's old/new rows), so a one-line update repaints one strip, not the
        // whole surface. Geometry change = everything moved: full repaint.
        guard old.rows == snap.rows, old.cols == snap.cols else {
            needsDisplay = true
            return
        }
        for row in 0..<snap.rows where rowChanged(old, snap, row) {
            setNeedsDisplay(rowRect(row))
        }
        if old.cursor != snap.cursor {
            if let c = old.cursor { setNeedsDisplay(rowRect(c.y)) }
            if let c = snap.cursor { setNeedsDisplay(rowRect(c.y)) }
        }
    }

    private func rowChanged(_ a: TerminalGrid, _ b: TerminalGrid, _ row: Int) -> Bool {
        let range = (row * a.cols)..<((row + 1) * a.cols)
        return a.cells[range] != b.cells[range]
    }

    private func rowRect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: inset + CGFloat(row) * cellSize.height,
               width: bounds.width, height: cellSize.height)
    }

    /// Mark the surface as ended: stop the read loop and show a clean, unobtrusive
    /// end banner so the window does not read as stuck. Idempotent.
    public func markEnded(_ disposition: SessionDisposition) {
        guard endBanner == nil else { return }
        stopReading()
        endBanner = disposition.endBanner
        needsDisplay = true
    }

    // MARK: - Input

    // Fractional wheel rows not yet applied (trackpads report sub-row deltas).
    private var scrollResidue: CGFloat = 0

    /// Wheel/trackpad scrolls the emulator viewport into scrollback; the next
    /// snapshot renders the scrolled view. Typing snaps back to the live bottom.
    public override func scrollWheel(with event: NSEvent) {
        let rowsDelta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / cellSize.height   // px → rows
            : event.scrollingDeltaY                     // already in lines
        scrollResidue += rowsDelta
        let rows = Int(scrollResidue)
        guard rows != 0 else { return }
        scrollResidue -= CGFloat(rows)
        // Wheel-up (positive deltaY) moves BACK into history (negative delta).
        session.terminal.scrollViewport(delta: -rows)
        refresh()
    }

    public override func keyDown(with event: NSEvent) {
        guard let input = Self.keyInput(from: event) else {
            super.keyDown(with: event)
            return
        }
        // Typing re-engages the live screen — standard terminal behavior.
        session.terminal.scrollViewportToBottom()
        // Every key — including Esc — flows straight to the PTY so an interactive
        // child (Claude Code's Esc / Esc-Esc) works. "Back to board" lives on ⌘[,
        // handled in `performKeyEquivalent`, not here.
        session.send(KeyEncoder.bytes(for: input))
    }

    /// `⌘[` returns to the host (drill-in → board). A Cmd-combo is delivered via the
    /// key-equivalent path before `keyDown`, regardless of first responder, and a
    /// terminal child never receives it — so it's the collision-free "Back" seam.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "[" where onBack?() == true:
            return true
        case "v":
            paste()
            return true
        case "c":
            copyScreen()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// ⌘V: send the pasteboard string to the child, honoring bracketed paste so a
    /// TUI (Claude Code, vim) receives it as one paste, not replayed keystrokes.
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty
        else { return }
        session.terminal.scrollViewportToBottom()
        let payload = session.terminal.bracketedPasteEnabled
            ? "\u{1B}[200~\(text)\u{1B}[201~" : text
        session.send(Array(payload.utf8))
    }

    /// ⌘C: copy the visible screen as plain text.
    /// ponytail: whole-screen copy, no mouse selection — add cell-range selection
    /// when copying a fragment matters more than copying the screen.
    private func copyScreen() {
        guard let text = try? session.terminal.plainText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Translate an `NSEvent` into a window-free ``KeyInput`` (the testable seam).
    nonisolated static func keyInput(from event: NSEvent) -> KeyInput? {
        if event.modifierFlags.contains(.control),
           let c = event.charactersIgnoringModifiers?.first, c.isLetter {
            return .control(c)
        }
        switch Int(event.keyCode) {
        case 36, 76: return .enter
        case 48: return .tab
        case 51: return .backspace
        case 53: return .escape
        case 126: return .up
        case 125: return .down
        case 124: return .right
        case 123: return .left
        default:
            guard let chars = event.characters, !chars.isEmpty else { return nil }
            return .text(chars)
        }
    }

    // MARK: - Rendering

    public override func draw(_ dirtyRect: NSRect) {
        BoardTheme.termBg.setFill()
        dirtyRect.fill()
        // Honor the damage rect: repaint only the rows it covers (refresh()
        // invalidates per-row strips, so this is what makes the diff pay off).
        if grid.rows > 0 {
            let first = max(0, Int((dirtyRect.minY - inset) / cellSize.height))
            let last = min(grid.rows - 1, Int((dirtyRect.maxY - inset) / cellSize.height))
            if first <= last {
                for row in first...last { drawRow(row) }
            }
        }
        drawCursor()
        drawEndBanner()
    }

    /// Draw one grid row as colour runs: consecutive cells sharing fg+bg are one
    /// fill + one string draw, so a full-width coloured line is a couple of draws,
    /// not one per cell. Monospace + zero kerning keeps the run grid-aligned.
    private func drawRow(_ row: Int) {
        var col = 0
        while col < grid.cols {
            let first = grid.cell(col: col, row: row)
            let start = col
            col += 1
            while col < grid.cols {
                let c = grid.cell(col: col, row: row)
                if c.fg != first.fg || c.bg != first.bg { break }
                col += 1
            }
            drawRun(row: row, from: start, to: col, fg: first.fg, bg: first.bg)
        }
    }

    private func drawRun(row: Int, from start: Int, to end: Int, fg: RGB?, bg: RGB?) {
        let x = inset + CGFloat(start) * cellSize.width
        let y = inset + CGFloat(row) * cellSize.height
        if let bg {
            nsColor(bg).setFill()
            NSRect(x: x, y: y, width: CGFloat(end - start) * cellSize.width, height: cellSize.height).fill()
        }
        let text = runText(row: row, from: start, to: end)
        guard text.contains(where: { $0 != " " }) else { return }   // blank run: bg only
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: glyphAttrs(fg: fg))
    }

    private func runText(row: Int, from start: Int, to end: Int) -> String {
        var s = ""
        s.reserveCapacity(end - start)
        for col in start..<end {
            if let scalar = grid.cell(col: col, row: row).scalar {
                s.unicodeScalars.append(scalar)
            } else {
                s.append(" ")
            }
        }
        return s
    }

    /// The real emulator cursor: a translucent block at its true viewport cell, with
    /// the glyph underneath re-drawn on top so it stays legible. ponytail: block
    /// style + fixed alpha (no bar/underline shape, no blink) — upgrade via the
    /// render-state CURSOR_VISUAL_STYLE/BLINKING fields if a TUI needs them.
    private func drawCursor() {
        guard endBanner == nil, let cur = grid.cursor, cur.visible,
              cur.x < grid.cols, cur.y < grid.rows else { return }
        let x = inset + CGFloat(cur.x) * cellSize.width
        let y = inset + CGFloat(cur.y) * cellSize.height
        BoardTheme.termCursor.withAlphaComponent(0.55).setFill()
        NSRect(x: x, y: y, width: cellSize.width, height: cellSize.height).fill()
        if let scalar = grid.cell(col: cur.x, row: cur.y).scalar {
            (String(scalar) as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: glyphAttrs(fg: nil))
        }
    }

    /// Draw the dim end banner one blank line below the last terminal row.
    private func drawEndBanner() {
        guard let endBanner else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemGray]
        let y = inset + CGFloat(grid.rows + 1) * cellSize.height
        (endBanner as NSString).draw(at: NSPoint(x: inset, y: y), withAttributes: attrs)
    }

    // MARK: - Colour helpers

    private func glyphAttrs(fg: RGB?) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: fg.map(nsColor) ?? defaultFgColor(),
         .ligature: 0, .kern: 0]
    }

    private func nsColor(_ c: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    private func defaultFgColor() -> NSColor {
        grid.defaultFg.map(nsColor) ?? BoardTheme.termFg
    }
}
