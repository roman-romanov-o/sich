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
    private let inset: CGFloat = 9
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

    /// The pasteboard ⌘V reads. `.general` in the app; a test injects a unique-name
    /// pasteboard so paste routing is assertable without clobbering the user's real
    /// clipboard.
    var pasteboard: NSPasteboard = .general
    /// The last rendered viewport (resolved cells + cursor); refreshed on PTY output.
    private var grid: TerminalGrid = .empty
    /// A dim end-of-session banner appended once the session terminates, so a
    /// finished window reads as *ended* rather than *hung*. `nil` while live.
    private var endBanner: String?
    private var selectionAnchor: GridPoint?
    private var selectionFocus: GridPoint?

    /// A local model of the current input line — the bytes typed since the last
    /// Enter, so a suggest-only driver (Planning Mode, US-004) can tell whether the
    /// user already has an unsent command in flight before it pre-types one. It is a
    /// *behavioural* model (driven by the same real keystrokes the child sees), not a
    /// screen-scrape of the shell's line editor: enough to answer "is the input line
    /// occupied?" without racing the emulator.
    public private(set) var unsentInput = ""

    /// The session this surface renders — exposed so a host (Planning Mode) can assert
    /// the terminal it mounted is the very session registered in ``SessionRegistry``
    /// (US-004 AC2), never a second, unregistered spawn.
    public var ptySession: PTYSession { session }

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
        applyBackgroundColor()
        // Clip drawing to our own bounds. Without this, a flipped, layer-backed
        // surface composites its black fill across the WHOLE host window (the dirty
        // rect it is handed spans the host, and an unclipped layer paints all of it),
        // burying the drill-in's header strip + "← board" pill behind a full-window
        // black rectangle even though the header's geometry is correct (hit-testing
        // still resolves to the pill — clicks worked while the chrome was invisible).
        layer?.masksToBounds = true
        // A dropped file pastes its path (the drag-a-screenshot-into-claude flow).
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    /// System light/dark flipped: the dynamic `termBg` cgColor was resolved for the old
    /// appearance, so re-resolve the layer fill and repaint (draw()'s own `.setFill()`
    /// calls already resolve live, but the layer backing needs a nudge).
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColor()
        needsDisplay = true
    }

    private func applyBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = BoardTheme.termBg.cgColor
        }
    }

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
        // Never leave the session holding output past this surface's lifetime —
        // an unmounted surface can't release the hold, and the buffer would grow
        // unwatched while the board pump keeps draining the pty.
        session.holdOutput = false
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
        if session.holdOutput, session.heldByteCount > Self.maxHeldBytes {
            clearSelection()             // abandoned selection: stop hoarding output
        }
        switch session.pumpAvailable() {
        case .data:
            if idleTicks >= Self.idleTickThreshold { scheduleTimer(hz: Self.activeHz) }
            idleTicks = 0
            refresh()
        case .idle:
            idleTicks += 1
            if idleTicks == Self.idleTickThreshold { scheduleTimer(hz: Self.idleHz) }
        case .eof:
            clearSelection()             // flush anything held before the banner
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

    /// Wheel/trackpad routing, in the order a stock terminal resolves it:
    /// 1. child enabled mouse tracking (Claude Code's chat pane, vim `mouse=a`)
    ///    → encode the wheel as the mouse report it asked for and send it down
    ///    the pty — the child owns scrolling, the viewport must NOT move;
    /// 2. child is on the alternate screen (less, plain vim) → there is no
    ///    scrollback there, send arrow keys (the xterm alternate-scroll idiom);
    /// 3. otherwise scroll the emulator viewport into scrollback.
    /// Typing snaps back to the live bottom.
    public override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let rowsDelta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / cellSize.height   // px → rows
            : event.scrollingDeltaY                     // already in lines
        scrollResidue += rowsDelta
        let rows = Int(scrollResidue)
        guard rows != 0 else { return }
        scrollResidue -= CGFloat(rows)
        if forwardWheelToChild(event, up: rows > 0, ticks: abs(rows)) { return }
        if sendAlternateScrollArrows(up: rows > 0, ticks: abs(rows)) { return }
        // Wheel-up (positive deltaY) moves BACK into history (negative delta).
        session.terminal.scrollViewport(delta: -rows)
        refresh()
    }

    private func forwardWheelToChild(_ event: NSEvent, up: Bool, ticks: Int) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = Terminal.MouseGeometry(
            screenWidth: UInt32(max(1, bounds.width)),
            screenHeight: UInt32(max(1, bounds.height)),
            cellWidth: UInt32(max(1, cellSize.width.rounded())),
            cellHeight: UInt32(max(1, cellSize.height.rounded())),
            padding: UInt32(inset))
        guard let bytes = session.terminal.encodeWheel(
            up: up, x: Float(point.x), y: Float(point.y), geometry: geometry)
        else { return false }   // no mouse tracking — fall through
        for _ in 0..<ticks { session.send(bytes) }
        return true
    }

    private func sendAlternateScrollArrows(up: Bool, ticks: Int) -> Bool {
        guard session.terminal.alternateScreenActive else { return false }
        let bytes = KeyEncoder.bytes(for: up ? .up : .down)
        for _ in 0..<ticks { session.send(bytes) }
        return true
    }

    // Selecting more than this much buffered output means the user abandoned the
    // selection mid-stream; release it rather than hold megabytes indefinitely.
    private static let maxHeldBytes = 2_000_000

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Freeze the grid for the duration of the selection: selection coords are
        // viewport-relative, so live output shifting rows beneath the pointer is
        // what made "select in terminal" broken. Output buffers in the session
        // (child stays unblocked) and flushes when the selection clears.
        session.holdOutput = true
        let point = convert(event.locationInWindow, from: nil)
        let cell = gridPoint(at: point)
        selectionAnchor = cell
        selectionFocus = cell
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard selectionAnchor != nil else { return }
        selectionFocus = gridPoint(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
        autoscrollSelectionIfNeeded(event)
    }

    public override func mouseUp(with event: NSEvent) {
        guard selectionAnchor != nil else { return }
        selectionFocus = gridPoint(at: convert(event.locationInWindow, from: nil))
        if selectionText().isEmpty {
            clearSelection()   // plain click: nothing selected, resume the stream
        }
        needsDisplay = true
    }

    public override func keyDown(with event: NSEvent) {
        guard let input = Self.keyInput(from: event) else {
            super.keyDown(with: event)
            return
        }
        // Typing re-engages the live screen — standard terminal behavior.
        session.terminal.scrollViewportToBottom()
        clearSelection()
        // Every key — including Esc — flows straight to the PTY so an interactive
        // child (Claude Code's Esc / Esc-Esc) works. "Back to board" lives on ⌘[,
        // handled in `performKeyEquivalent`, not here.
        session.send(KeyEncoder.bytes(for: input))
        trackUnsent(input)
    }

    /// Mirror a real keystroke into the local input-line model so a suggest-only host
    /// can tell whether the user has an unsent command in flight (US-004 AC4). Only the
    /// keys that visibly build a shell line matter; everything else leaves it untouched.
    private func trackUnsent(_ input: KeyInput) {
        switch input {
        case .text(let s): unsentInput += s
        case .enter: unsentInput = ""
        case .backspace where !unsentInput.isEmpty: unsentInput.removeLast()
        case .control("u"), .control("c"), .escape: unsentInput = ""
        default: break
        }
    }

    /// Is the input line occupied? A step click must never overwrite an unsent command.
    public var hasUnsentInput: Bool { !unsentInput.isEmpty }

    /// Pre-type a suggested command into the child WITHOUT a trailing newline, so the
    /// user reviews and presses Enter (US-004 AC3 — suggest, never submit). Returns
    /// `false` and touches nothing when the input line is already occupied (AC4).
    @discardableResult
    public func insertSuggested(_ command: String) -> Bool {
        guard !hasUnsentInput else { return false }
        session.terminal.scrollViewportToBottom()
        clearSelection()
        session.send(Array(command.utf8))
        unsentInput = command
        return true
    }

    /// `⌘[` returns to the host (drill-in → board). A Cmd-combo is delivered via the
    /// key-equivalent path before `keyDown`, regardless of first responder, and a
    /// terminal child never receives it — so it's the collision-free "Back" seam.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        // ⌘←/⌘→/⌘⌫ are editing keys for the child (line start/end, kill line);
        // they arrive on the key-equivalent path, never reaching keyDown.
        if [123, 124, 51].contains(Int(event.keyCode)),
           let input = Self.keyInput(from: event) {
            session.terminal.scrollViewportToBottom()
            session.send(KeyEncoder.bytes(for: input))
            return true
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

    /// ⌘V: classify the pasteboard and send what the child expects — text honors
    /// bracketed paste; copied files paste as shell-escaped paths; an image-only
    /// clipboard sends the ⌃V trigger so the child (Claude Code) reads the OS
    /// clipboard itself, exactly as it does in a stock terminal. (Plain ⌃V also
    /// still flows through `keyDown` untouched — the vanilla chord keeps working.)
    private func paste() {
        guard let payload = Self.pastePayload(from: pasteboard) else { return }
        session.terminal.scrollViewportToBottom()
        clearSelection()
        session.send(PasteEncoder.bytes(
            for: payload, bracketed: session.terminal.bracketedPasteEnabled))
    }

    /// Classify one paste gesture. Files beat text: Finder's "Copy" also puts the
    /// bare file *name* on the pasteboard as a string, and the full path is the
    /// useful form (Terminal.app's policy). Text beats image: a web "copy" often
    /// carries both, and ⌘V staying a text paste matches every terminal — the
    /// image trigger fires only when there is nothing textual to paste.
    nonisolated static func pastePayload(from pb: NSPasteboard) -> PastePayload? {
        let files = fileURLs(from: pb)
        if !files.isEmpty { return .filePaths(files.map(\.path)) }
        if let text = pb.string(forType: .string), !text.isEmpty { return .text(text) }
        let imageTypes = [NSPasteboard.PasteboardType.png.rawValue,
                          NSPasteboard.PasteboardType.tiff.rawValue]
        if pb.canReadItem(withDataConformingToTypes: imageTypes) { return .imageOnClipboard }
        return nil
    }

    nonisolated private static func fileURLs(from pb: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    // MARK: - File drop → path paste

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.fileURLs(from: sender.draggingPasteboard).map(\.path)
        guard !paths.isEmpty else { return false }
        session.terminal.scrollViewportToBottom()
        clearSelection()
        // Trailing space, like Terminal.app's drop: the user keeps typing after it.
        session.send(PasteEncoder.bytes(
            for: .filePaths(paths),
            bracketed: session.terminal.bracketedPasteEnabled) + Array(" ".utf8))
        return true
    }

    /// ⌘C: copy the visible screen as plain text.
    /// ponytail: whole-screen copy, no mouse selection — add cell-range selection
    /// when copying a fragment matters more than copying the screen.
    private func copyScreen() {
        if let selected = selectedTextForCopy(), !selected.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selected, forType: .string)
            return
        }
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
        let flags = event.modifierFlags
        let word = flags.contains(.control) || flags.contains(.option)
        switch Int(event.keyCode) {
        case 36, 76: return .enter
        case 48: return .tab
        case 51 where flags.contains(.command): return .deleteLine
        case 51 where word: return .deleteWord
        case 51: return .backspace
        case 53: return .escape
        case 126: return .up
        case 125: return .down
        case 124 where flags.contains(.command): return .lineEnd
        case 124 where word: return .wordRight
        case 124: return .right
        case 123 where flags.contains(.command): return .lineStart
        case 123 where word: return .wordLeft
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
        drawSelection()
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

    private struct GridPoint: Equatable {
        var row: Int
        var col: Int
    }

    private func gridPoint(at point: NSPoint) -> GridPoint {
        guard grid.rows > 0, grid.cols > 0 else { return GridPoint(row: 0, col: 0) }
        let col = max(0, min(grid.cols - 1, Int((point.x - inset) / cellSize.width)))
        let row = max(0, min(grid.rows - 1, Int((point.y - inset) / cellSize.height)))
        return GridPoint(row: row, col: col)
    }

    private func orderedSelection() -> (start: GridPoint, end: GridPoint)? {
        guard let a = selectionAnchor, let b = selectionFocus, a != b else { return nil }
        if a.row < b.row || (a.row == b.row && a.col <= b.col) { return (a, b) }
        return (b, a)
    }

    private func drawSelection() {
        guard let range = orderedSelection() else { return }
        BoardTheme.brand.withAlphaComponent(0.32).setFill()
        for row in range.start.row...range.end.row {
            let startCol = row == range.start.row ? range.start.col : 0
            let endCol = row == range.end.row ? range.end.col : grid.cols - 1
            guard endCol >= startCol else { continue }
            NSRect(
                x: inset + CGFloat(startCol) * cellSize.width,
                y: inset + CGFloat(row) * cellSize.height,
                width: CGFloat(endCol - startCol + 1) * cellSize.width,
                height: cellSize.height
            ).fill()
        }
    }

    private func selectedTextForCopy() -> String? {
        let text = selectionText()
        return text.isEmpty ? nil : text
    }

    private func selectionText() -> String {
        guard let range = orderedSelection(), grid.rows > 0, grid.cols > 0 else { return "" }
        var lines: [String] = []
        for row in range.start.row...range.end.row {
            let startCol = row == range.start.row ? range.start.col : 0
            let endCol = row == range.end.row ? range.end.col : grid.cols - 1
            var line = ""
            for col in startCol...endCol {
                if let scalar = grid.cell(col: col, row: row).scalar {
                    line.unicodeScalars.append(scalar)
                } else {
                    line.append(" ")
                }
            }
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }
        return lines.joined(separator: "\n")
    }

    private func clearSelection() {
        session.holdOutput = false   // resume the live stream (flushes held bytes)
        guard selectionAnchor != nil || selectionFocus != nil else { return }
        selectionAnchor = nil
        selectionFocus = nil
        needsDisplay = true
    }

    private func autoscrollSelectionIfNeeded(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < inset {
            session.terminal.scrollViewport(delta: -1)
            refresh()
        } else if point.y > bounds.maxY - inset {
            session.terminal.scrollViewport(delta: 1)
            refresh()
        }
    }
}
