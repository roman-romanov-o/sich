import AppKit
import SichCore
import os

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
    private var readSource: DispatchSourceRead?
    private let font: NSFont
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
    private var refreshQueue = TerminalRefreshQueue()
    /// Whether the scrollback pill was on screen at the last repaint — a flip
    /// is the one case the row damage-diff cannot express, so it forces a full one.
    private var badgeWasVisible = false
    private var scrollAccumulator = TerminalScrollAccumulator()
    /// Wheel motion (rows, wheel-up positive) not yet applied to the viewport.
    /// Applied at frame time, against the emulator's real position, so a scroll
    /// that clamps at the live screen can never leave a phantom fraction behind.
    private var pendingScroll: CGFloat = 0
    /// Sub-row scroll position, 0 ≤ fraction < 1: the row stack is drawn shifted
    /// UP by this many rows, with the row just below the viewport sliding in at
    /// the bottom. Only ever non-zero while the viewport sits in history.
    private var scrollFraction: CGFloat = 0
    /// The history row below the viewport, shown under the last row while
    /// `scrollFraction > 0`.
    private var rowBelow: [TerminalCell]?
    /// Set by a viewport/geometry change: the next idle frame pre-renders the
    /// screen above into the row cache so the first flick into history finds its
    /// rows already painted.
    private var prefetchArmed = false
    /// Rows are Core Animation layers showing content-keyed cached row images
    /// (``TerminalRowLayerHost``); selection, cursor, banner and pill paint in the
    /// overlay above them. A scroll frame is pointer swaps plus a GPU composite.
    private let rowHost = TerminalRowLayerHost(frame: .zero)
    private let overlay = TerminalOverlayView(frame: .zero)
    private let rowCache = TerminalRowCache()
    private lazy var frameCoordinator = TerminalFrameCoordinator { [weak self] in
        self?.displayFrame() ?? false
    }

    private static let performanceLog = OSLog(
        subsystem: "com.sich.terminal", category: .pointsOfInterest)

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
    ///
    /// The height, though, is rounded UP to whole device pixels: a row layer sits
    /// at `row * cellHeight`, and a fractional origin would make Core Animation
    /// resample its image (blurry glyphs). Width stays fractional — it only
    /// positions text within one row image.
    private lazy var cellSize: CGSize = {
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let h = ((font.ascender - font.descender + font.leading) * scale).rounded(.up) / scale
        return CGSize(width: w, height: h)
    }()

    public init(session: PTYSession, fontSize: CGFloat = 20) {
        self.session = session
        self.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        super.init(frame: .zero)
        themedBackground = BoardTheme.termBg
        applyTerminalTheme()
        // Clip drawing to our own bounds. Without this, a flipped, layer-backed
        // surface composites its black fill across the WHOLE host window (the dirty
        // rect it is handed spans the host, and an unclipped layer paints all of it),
        // burying the drill-in's header strip + "← board" pill behind a full-window
        // black rectangle even though the header's geometry is correct (hit-testing
        // still resolves to the pill — clicks worked while the chrome was invisible).
        layer?.masksToBounds = true
        // A dropped file pastes its path (the drag-a-screenshot-into-claude flow).
        registerForDraggedTypes([.fileURL])
        addSubview(rowHost)   // framed to the grid rect by `syncRowLayers`
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        overlay.drawHandler = { [weak self] _ in self?.drawOverlay() }
    }

    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    /// System light/dark flipped. The layer fill re-resolves itself (`themedBackground`),
    /// and `draw()`'s own `.setFill()` calls already resolve live — but the emulator sits
    /// below AppKit and can't see an NSColor, so its palette has to be re-pushed by hand.
    /// That's what keeps the child's *content* colours flipping with the surface instead
    /// of leaving dark-console ANSI stranded on light paper.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cachedTerminalBackground = nil
        glyphAttrsCache.removeAll(keepingCapacity: true)
        rowCache.removeAll()   // rows were painted in the old palette
        applyTerminalTheme()
        requestRefresh(.full) // cells re-resolve through the new palette
    }

    /// Moved to a display with another scale: cached rows carry the old backing
    /// resolution, so drop them rather than show blurry 1x rows on a 2x screen.
    // periphery:ignore - NSView override; `public` is required by the open class
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rowCache.removeAll()
        syncRowLayers(changedFrom: nil)
    }

    /// Push this appearance's colour theme into the emulator so the child's ANSI
    /// colours are *ours*, not libghostty's built-in dark-oriented defaults. libghostty
    /// resolves a cell's palette index when the render state is read, so this re-colours
    /// existing scrollback as well as new output — the flip is retroactive, no reflow.
    private func applyTerminalTheme() {
        session.terminal.apply(theme: BoardTheme.terminalTheme(for: effectiveAppearance))
        // Claude paints its own TUI, below our palette. It watches the themes
        // directory, so rewriting the file here re-colours the running child too —
        // a flip mid-session doesn't leave its chrome on the side we just left.
        ClaudeTheme.install(for: effectiveAppearance)
    }

    /// Item 8 (18.08): a drill-in surface teaches the board its settled grid so the
    /// NEXT spawn is born that shape. Off by default — planning-mode panes and test
    /// surfaces are narrower than the drill-in viewport and must not pollute it.
    var teachesGeometry = false

    // MARK: - Links (item 9, 18.08)

    /// The card's project dir — relative file links on screen resolve against it.
    var workingDirectory: String?

    /// How a ⌘-clicked link leaves the app. Injectable so tests can catch the URL
    /// instead of actually launching a browser/Finder.
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }

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
        if teachesGeometry {
            TerminalGeometry.remember(rows: UInt16(rows), cols: UInt16(cols))
        }
        requestRefresh(.full)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncTerminalSize()
    }

    // MARK: - PTY read loop

    /// Start reading the PTY on the main run loop so the emulator screen stays
    /// live without screen-scraping. Idempotent.
    ///
    /// Production delivery is fd-readiness driven, so the first byte after an idle
    /// prompt does not wait for the polling interval. A low-frequency run-loop timer
    /// remains as a backstop because a plain spun run loop (tests and some nested
    /// AppKit modes) does not necessarily drain `.main` dispatch sources.
    public func startReading() {
        guard readTimer == nil, session.masterFD >= 0 else { return }
        session.setNonBlocking()
        syncTerminalSize()   // match the child to the window before the first paint
        armReadSource()
        scheduleTimer(hz: Self.idleHz)
        onTick()   // paint whatever is already buffered without waiting a frame
    }

    public func stopReading() {
        // Never leave the session holding output past this surface's lifetime —
        // an unmounted surface can't release the hold, and the buffer would grow
        // unwatched while the board pump keeps draining the pty.
        session.holdOutput = false
        readSource?.cancel()
        readSource = nil
        readTimer?.invalidate()
        readTimer = nil
    }

    // Adaptive cadence: 60Hz while output flows, 4Hz once the child has been
    // quiet for ~1s — the shell-at-its-prompt case that otherwise burns battery.
    // First byte after idle upshifts immediately (worst added latency: 250ms).
    private static let activeHz = 60.0
    private static let idleHz = 4.0
    private static let idleTickThreshold = 60   // ~1s of silence at 60Hz
    private var idleTicks = 0
    private var readHz = idleHz
    private func armReadSource() {
        guard readSource == nil, session.masterFD >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: session.masterFD, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.onReadable() }
        }
        readSource = source
        source.resume()
    }

    private func scheduleTimer(hz: Double) {
        readTimer?.invalidate()
        readHz = hz
        let timer = Timer(timeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        readTimer = timer
    }

    private func onTick() {
        consumeAvailableOutput()
    }

    private func onReadable() {
        consumeAvailableOutput()
    }

    private func consumeAvailableOutput() {
        if session.holdOutput, session.heldByteCount > Self.maxHeldBytes {
            clearSelection()             // abandoned selection: stop hoarding output
        }
        switch session.pumpAvailable() {
        case .data:
            if readHz != Self.activeHz { scheduleTimer(hz: Self.activeHz) }
            idleTicks = 0
            requestRefresh(.output)
        case .idle:
            idleTicks += 1
            if idleTicks == Self.idleTickThreshold { scheduleTimer(hz: Self.idleHz) }
        case .eof:
            clearSelection()             // flush anything held before the banner
            stopReading()                // child gone
        }
    }

    /// Coalesce output, scrolling and geometry changes to the next refresh of the
    /// display containing this window, at that display's native cadence.
    private func requestRefresh(_ reason: TerminalRefreshReason) {
        refreshQueue.request(reason)
        frameCoordinator.requestFrame()
    }

    /// One display-link frame: consume the coalesced damage and repaint. Returns
    /// whether there was work — the coordinator uses a run of workless frames to
    /// pause itself once output goes quiet.
    private func displayFrame() -> Bool {
        guard let reason = refreshQueue.consume() else {
            if prefetchArmed {
                prefetchArmed = false
                prefetchRowsAbove()
            }
            return false
        }
        refresh(reason: reason)
        return true
    }

    /// (Re)bind the frame clock to the display that actually contains this window —
    /// `NSView.displayLink` follows the view across displays, so a move to the
    /// 144Hz screen re-paces frames automatically.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frameCoordinator.attach(to: self)
        // Damage requested while unhosted was delivered via the headless fallback,
        // but anything still pending should ride the fresh link immediately.
        if window != nil, refreshQueue.pending != nil { frameCoordinator.requestFrame() }
    }

    private func refresh(reason: TerminalRefreshReason = .output) {
        let signpost = OSSignpostID(log: Self.performanceLog)
        os_signpost(.begin, log: Self.performanceLog, name: "Terminal snapshot", signpostID: signpost)
        defer { os_signpost(.end, log: Self.performanceLog, name: "Terminal snapshot", signpostID: signpost) }
        let snap = applyPendingScroll()
        guard snap.rows > 0 else { return }   // never blank a good screen on a failed read
        let old = grid
        grid = snap
        rowBelow = scrollFraction > 0 ? fetchRowBelow(snap) : nil
        let badgeFlipped = badgeWasVisible != isViewingScrollback
        badgeWasVisible = isViewingScrollback
        // Cached rows were resolved against the old default colours (OSC 10/11).
        let paletteChanged = old.defaultFg != snap.defaultFg || old.defaultBg != snap.defaultBg
        if paletteChanged { rowCache.removeAll() }
        // A viewport shift or a geometry change moves every row; plain output is
        // diffed so a one-line update touches one row layer.
        let incremental = reason == .output && !paletteChanged
            && old.rows == snap.rows && old.cols == snap.cols
        syncRowLayers(changedFrom: incremental ? old : nil)
        if reason != .output { prefetchArmed = true }
        if !incremental || badgeFlipped || old.cursor != snap.cursor
            || snap.cursor.map({ rowChanged(old, snap, $0.y) }) == true {
            overlay.needsDisplay = true
        }
    }

    private func rowChanged(_ old: TerminalGrid, _ new: TerminalGrid, _ row: Int) -> Bool {
        let range = (row * old.cols)..<((row + 1) * old.cols)
        return old.cells[range] != new.cells[range]
    }

    // MARK: - Smooth scrolling

    /// Move the viewport by the wheel motion gathered since the last frame and
    /// return the fresh snapshot. Whole rows go to the emulator; the remainder is
    /// the sub-row shift. Two clamps keep the fraction honest: the live screen is
    /// the bottom (a live viewport never carries a fraction), and a scroll into
    /// history that the emulator cut short at the top drops its fraction too.
    /// How far the emulator moved is read from its own viewport offset — never
    /// inferred from row contents, which a TUI repaints between any two frames.
    private func applyPendingScroll() -> TerminalGrid {
        let terminal = session.terminal
        guard pendingScroll != 0 else { return terminal.snapshot() }
        let target = scrollFraction - pendingScroll   // wheel-up = toward history
        pendingScroll = 0
        let whole = Int(target.rounded(.down))
        scrollFraction = target - CGFloat(whole)
        if whole != 0 {
            let before = terminal.viewportOffset
            terminal.scrollViewport(delta: whole)
            if whole < 0, before - terminal.viewportOffset < -whole { scrollFraction = 0 }   // top of scrollback
        }
        let snap = terminal.snapshot()
        if snap.live { scrollFraction = 0 }   // the live screen is the bottom
        return snap
    }

    /// The row just below the viewport. Only asked for in history (a fraction is
    /// never live), so the step down always moves and the step back is exact.
    private func fetchRowBelow(_ snap: TerminalGrid) -> [TerminalCell]? {
        let terminal = session.terminal
        terminal.scrollViewport(delta: 1)
        let down = terminal.snapshot()
        terminal.scrollViewport(delta: -1)
        guard down.rows == snap.rows, down.cols == snap.cols, down.cols > 0 else { return nil }
        return Array(down.cells[((down.rows - 1) * down.cols)...])
    }

    /// Idle-frame work: paint the screen above the viewport into the row cache so
    /// a flick into history is served from cache from its first frame. The
    /// viewport is put back exactly — `scrollViewportToBottom` when live, else by
    /// the offset the emulator reports it moved (row contents can't tell: a TUI's
    /// history is bands of identical blank rows).
    private func prefetchRowsAbove() {
        let terminal = session.terminal
        guard grid.rows > 0, grid.cols > 0, !terminal.alternateScreenActive else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let offset = terminal.viewportOffset
        terminal.scrollViewport(delta: -grid.rows)
        let above = terminal.snapshot()
        defer {
            if grid.live {
                terminal.scrollViewportToBottom()
            } else {
                terminal.scrollViewport(delta: offset - terminal.viewportOffset)
            }
        }
        guard above.rows == grid.rows, above.cols == grid.cols, above.cells != grid.cells else { return }
        for row in 0..<above.rows {
            _ = image(forCells: above.cells[(row * above.cols)..<((row + 1) * above.cols)], scale: scale)
        }
    }

    /// Mark the surface as ended: stop the read loop and show a clean, unobtrusive
    /// end banner so the window does not read as stuck. Idempotent.
    public func markEnded(_ disposition: SessionDisposition) {
        guard endBanner == nil else { return }
        stopReading()
        endBanner = disposition.endBanner
        overlay.needsDisplay = true
    }

    // MARK: - Input

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
        let delta = TerminalScrollAccumulator.rowDelta(
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            cellHeight: cellSize.height)
        guard delta != 0 else { return }
        if session.terminal.alternateScreenActive || childTracksMouse(event) {
            // The child consumes whole ticks; sub-row motion carries over.
            let rows = scrollAccumulator.rows(adding: delta)
            guard rows != 0 else { return }
            if forwardWheelToChild(event, up: rows > 0, ticks: abs(rows)) { return }
            sendAlternateScrollArrows(up: rows > 0, ticks: abs(rows))
            return
        }
        // Our own viewport scrolls by pixels, momentum included: whole rows move
        // the emulator at frame time, the remainder shifts the row stack.
        pendingScroll += delta
        requestRefresh(.viewport)
    }

    private func mouseGeometry() -> Terminal.MouseGeometry {
        Terminal.MouseGeometry(
            screenWidth: UInt32(max(1, bounds.width)),
            screenHeight: UInt32(max(1, bounds.height)),
            cellWidth: UInt32(max(1, cellSize.width.rounded())),
            cellHeight: UInt32(max(1, cellSize.height.rounded())),
            padding: UInt32(inset))
    }

    private func childTracksMouse(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return session.terminal.encodeWheel(
            up: true, x: Float(point.x), y: Float(point.y), geometry: mouseGeometry()) != nil
    }

    private func forwardWheelToChild(_ event: NSEvent, up: Bool, ticks: Int) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard let bytes = session.terminal.encodeWheel(
            up: up, x: Float(point.x), y: Float(point.y), geometry: mouseGeometry())
        else { return false }   // no mouse tracking — fall through
        for _ in 0..<ticks { session.send(bytes) }
        return true
    }

    private func sendAlternateScrollArrows(up: Bool, ticks: Int) {
        let bytes = KeyEncoder.bytes(for: up ? .up : .down)
        for _ in 0..<ticks { session.send(bytes) }
    }

    // Selecting more than this much buffered output means the user abandoned the
    // selection mid-stream; release it rather than hold megabytes indefinitely.
    private static let maxHeldBytes = 2_000_000

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if isViewingScrollback,
           scrollbackBadgeRect().contains(convert(event.locationInWindow, from: nil)) {
            returnToLiveBottom()
            return
        }
        // ⌘-click on a highlighted URL/file opens it (item 9, 18.08) — the standard
        // terminal gesture — and never starts a selection.
        if event.modifierFlags.contains(.command),
           openLink(at: gridPoint(at: convert(event.locationInWindow, from: nil))) {
            return
        }
        // Freeze the grid for the duration of the selection: selection coords are
        // viewport-relative, so live output shifting rows beneath the pointer is
        // what made "select in terminal" broken. Output buffers in the session
        // (child stays unblocked) and flushes when the selection clears.
        session.holdOutput = true
        let point = convert(event.locationInWindow, from: nil)
        let cell = gridPoint(at: point)
        selectionAnchor = cell
        selectionFocus = cell
        overlay.needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard selectionAnchor != nil else { return }
        selectionFocus = gridPoint(at: convert(event.locationInWindow, from: nil))
        overlay.needsDisplay = true
        autoscrollSelectionIfNeeded(event)
    }

    public override func mouseUp(with event: NSEvent) {
        guard selectionAnchor != nil else { return }
        selectionFocus = gridPoint(at: convert(event.locationInWindow, from: nil))
        if selectionText().isEmpty {
            clearSelection()   // plain click: nothing selected, resume the stream
        }
        overlay.needsDisplay = true
    }

    public override func keyDown(with event: NSEvent) {
        guard let input = Self.keyInput(from: event) else {
            super.keyDown(with: event)
            return
        }
        // Typing re-engages the live screen — standard terminal behavior.
        returnToLiveBottom()
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
        returnToLiveBottom()
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
        // ⌘↑/⌘↓ walk the user's own prompts in the transcript — the "previous
        // mark" gesture of Terminal.app, aimed at Claude Code's prompt echoes.
        switch Int(event.keyCode) {
        case 126: jumpToUserPrompt(previous: true); return true
        case 125: jumpToUserPrompt(previous: false); return true
        default: break
        }
        // ⌘←/⌘→/⌘⌫ are editing keys for the child (line start/end, kill line);
        // they arrive on the key-equivalent path, never reaching keyDown.
        if [123, 124, 51].contains(Int(event.keyCode)),
           let input = Self.keyInput(from: event) {
            returnToLiveBottom()
            session.send(KeyEncoder.bytes(for: input))
            return true
        }
        // Match the Latin key, not the active layout's character. On Ukrainian
        // the V key reports "м", and a string compare against "v" never pasted.
        switch ASCIILayoutKey.shortcutCharacter(for: event) {
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
        returnToLiveBottom()
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
        returnToLiveBottom()
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
        // ⌃C / ⌃V follow the Latin key. A Cyrillic letter is still `isLetter`,
        // but it has no control code — the old path encoded "м" to zero bytes
        // and the chord vanished.
        if event.modifierFlags.contains(.control),
           let c = ASCIILayoutKey.shortcutCharacter(for: event),
           ("a"..."z").contains(c) {
            return .control(c)
        }
        let flags = event.modifierFlags
        let word = flags.contains(.control) || flags.contains(.option)
        switch Int(event.keyCode) {
        // Shift+Enter (and Option+Enter) insert a newline instead of submitting —
        // the multi-line-prompt chord Claude Code's `/terminal-setup` normally wires
        // up by hand. We map it natively so it works out of the box.
        case 36, 76:
            return flags.contains(.shift) || flags.contains(.option) ? .newline : .enter
        case 48: return flags.contains(.shift) ? .backtab : .tab
        case 51 where flags.contains(.command): return .deleteLine
        case 51 where word: return .deleteWord
        case 51: return .backspace
        case 53: return .escape
        case 126: return .up
        case 125: return .down
        case 116: return .pageUp
        case 121: return .pageDown
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

    /// Push the grid into the row layers. `changedFrom` is the previous grid for an
    /// output-diffed update (same geometry): only rows that differ are touched.
    /// `nil` resyncs every row (viewport scroll, resize, theme or scale change).
    private func syncRowLayers(changedFrom old: TerminalGrid?) {
        let signpost = OSSignpostID(log: Self.performanceLog)
        os_signpost(.begin, log: Self.performanceLog, name: "Terminal rows", signpostID: signpost)
        defer { os_signpost(.end, log: Self.performanceLog, name: "Terminal rows", signpostID: signpost) }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        rowCache.beginFrame()
        let rowSize = rowImageSize(scale: scale)
        let visible = grid.cols > 0 ? grid.rows : 0
        let gridRect = NSRect(x: inset, y: inset, width: rowSize.width,
                              height: CGFloat(visible) * rowSize.height)
        if rowHost.frame != gridRect { rowHost.frame = gridRect }
        rowHost.layout(rowCount: visible == 0 ? 0 : visible + 1, rowSize: rowSize, scale: scale)
        rowHost.setScrollOffset(scrollFraction * rowSize.height)
        for row in 0..<visible {
            if let old, !rowChanged(old, grid, row) { continue }
            rowHost.show(rowImage(row, scale: scale), atRow: row)
        }
        if visible > 0 {
            rowHost.show(rowBelow.flatMap { image(forCells: $0[...], scale: scale) }, atRow: visible)
        }
        // Only a full pass touched every visible row's entry, so only then can a
        // trim tell "unused this frame" from "untouched because unchanged".
        if old == nil { rowCache.trim(capacity: grid.rows * 5 + 32) }
    }

    /// A row image is exactly `cols` cells wide, rounded up to whole device pixels,
    /// and its layer takes that same size so the composite is 1:1, never resampled.
    private func rowImageSize(scale: CGFloat) -> CGSize {
        CGSize(width: (CGFloat(grid.cols) * cellSize.width * scale).rounded(.up) / scale,
               height: cellSize.height)
    }

    private func rowImage(_ row: Int, scale: CGFloat) -> CGImage? {
        image(forCells: grid.cells[(row * grid.cols)..<((row + 1) * grid.cols)], scale: scale)
    }

    private func image(forCells cells: ArraySlice<TerminalCell>, scale: CGFloat) -> CGImage? {
        guard cells.contains(where: { $0 != .blank }) else { return nil }   // bg shows through
        return rowCache.image(for: TerminalRowKey(cells: Array(cells), scale: scale)) { renderRow($0) }
    }

    /// Lay out one row into an opaque bitmap at the backing scale, upright (flipped
    /// CTM under a flipped `NSGraphicsContext` — the standard AppKit recipe) so Core
    /// Animation shows it top-down. Opaque with font smoothing on keeps the glyph
    /// anti-aliasing the direct-draw look had.
    private func renderRow(_ key: TerminalRowKey) -> CGImage? {
        let size = CGSize(width: CGFloat(key.cells.count) * cellSize.width, height: cellSize.height)
        let width = Int((size.width * key.scale).rounded(.up))
        let height = Int((size.height * key.scale).rounded())
        guard width > 0, height > 0, let bitmap = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        bitmap.setAllowsFontSmoothing(true)
        bitmap.setShouldSmoothFonts(true)
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: key.scale, y: -key.scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
        // Outside draw(_:) a dynamic colour resolves against whatever appearance is
        // current, so pin ours — the row must match the surface it sits on.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            BoardTheme.termBg.setFill()
            NSRect(x: 0, y: 0, width: CGFloat(width) / key.scale, height: size.height).fill()
            drawRuns(key.cells)
            drawLinkUnderlines(key.cells)
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.makeImage()
    }

    /// The overlay's paint — everything that is not a row, above the rows.
    private func drawOverlay() {
        drawSelection()
        drawCursor()
        drawEndBanner()
        drawScrollbackBadge()
    }

    /// Where grid row `row` is drawn: rows shift up by the sub-row fraction.
    private func rowTop(_ row: Int) -> CGFloat {
        inset + (CGFloat(row) - scrollFraction) * cellSize.height
    }

    /// Draw one row as colour runs: consecutive cells sharing fg+bg+style are one
    /// fill + one string draw, so a full-width coloured line is a couple of draws,
    /// not one per cell. Monospace + zero kerning keeps the run grid-aligned.
    private func drawRuns(_ cells: [TerminalCell]) {
        var col = 0
        while col < cells.count {
            let first = cells[col]
            let start = col
            col += 1
            while col < cells.count {
                let c = cells[col]
                if c.fg != first.fg || c.bg != first.bg || c.style != first.style { break }
                col += 1
            }
            drawRun(cells[start..<col], at: CGFloat(start) * cellSize.width, cell: first)
        }
    }

    /// Item 9 (18.08): URLs and file paths get a hairline underline in the link
    /// accent, so they read as clickable without repainting the glyphs themselves.
    private func drawLinkUnderlines(_ cells: [TerminalCell]) {
        for link in TerminalLinkDetector.links(in: Self.text(of: cells[...])) {
            let x = CGFloat(link.columns.lowerBound) * cellSize.width
            let width = CGFloat(link.columns.count) * cellSize.width
            BoardTheme.termLink.setFill()
            NSRect(x: x, y: cellSize.height - 1.5, width: width, height: 1).fill()
        }
    }

    private func links(in row: Int) -> [TerminalLink] {
        guard grid.cols > 0 else { return [] }
        let range = (row * grid.cols)..<((row + 1) * grid.cols)
        return TerminalLinkDetector.links(in: Self.text(of: grid.cells[range]))
    }

    /// Resolve and open the link under `point`, if any. Returns whether one opened —
    /// mouseDown uses that to swallow the click instead of starting a selection.
    private func openLink(at point: GridPoint) -> Bool {
        guard let link = links(in: point.row).first(where: { $0.columns.contains(point.col) }),
              let url = Self.resolve(link, against: workingDirectory) else { return false }
        openLink(url)
        return true
    }

    /// A URL opens as-is; a file span sheds its `:line[:col]` suffix, expands `~`,
    /// resolves relative against the card's project dir, and only opens if it
    /// actually exists here (the screen may be showing another machine's paths).
    static func resolve(_ link: TerminalLink, against workingDirectory: String?) -> URL? {
        switch link.kind {
        case .url:
            return URL(string: link.text)
        case .file:
            var path = link.text
            // `Sources/App/File.swift:12:5` → the path part only.
            if let match = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
                path.removeSubrange(match)
            }
            path = (path as NSString).expandingTildeInPath
            if !path.hasPrefix("/") {
                guard let base = workingDirectory else { return nil }
                path = (base as NSString).appendingPathComponent(path)
            }
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    /// One run in row-local space (y = 0 is the row's top): its bg fill, then its
    /// text as a single grid-aligned string.
    private func drawRun(_ run: ArraySlice<TerminalCell>, at x: CGFloat, cell: TerminalCell) {
        let colors = effectiveColors(for: cell)
        if let bg = colors.bg {
            nsColor(bg).setFill()
            NSRect(x: x, y: 0, width: CGFloat(run.count) * cellSize.width, height: cellSize.height).fill()
        }
        guard !cell.style.invisible else { return }
        let text = Self.text(of: run)
        guard text.contains(where: { $0 != " " }) else { return }   // blank run: bg only
        (text as NSString).draw(
            at: NSPoint(x: x, y: 0),
            withAttributes: glyphAttrs(fg: colors.fg, bg: colors.bg, style: cell.style))
    }

    private func effectiveColors(for cell: TerminalCell) -> (fg: RGB?, bg: RGB?) {
        guard cell.style.inverse else { return (cell.fg, cell.bg) }
        return (cell.bg ?? grid.defaultBg, cell.fg ?? grid.defaultFg)
    }

    private static func text(of cells: ArraySlice<TerminalCell>) -> String {
        var s = ""
        s.reserveCapacity(cells.count)
        for cell in cells {
            if let scalar = cell.scalar {
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
        let y = rowTop(cur.y)
        BoardTheme.termCursor.withAlphaComponent(0.55).setFill()
        NSRect(x: x, y: y, width: cellSize.width, height: cellSize.height).fill()
        if let scalar = grid.cell(col: cur.x, row: cur.y).scalar {
            let cell = grid.cell(col: cur.x, row: cur.y)
            let colors = effectiveColors(for: cell)
            (String(scalar) as NSString).draw(
                at: NSPoint(x: x, y: y),
                withAttributes: glyphAttrs(fg: colors.fg, bg: colors.bg, style: cell.style))
        }
    }

    /// Draw the dim end banner one blank line below the last terminal row.
    private func drawEndBanner() {
        guard let endBanner else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemGray]
        let y = inset + CGFloat(grid.rows + 1) * cellSize.height
        (endBanner as NSString).draw(at: NSPoint(x: inset, y: y), withAttributes: attrs)
    }

    // MARK: - Scrollback

    /// True while the viewport is parked in history instead of on the live screen.
    /// libghostty reports a viewport cursor only while the active screen is visible,
    /// so this reads the emulator directly rather than counting our own scroll deltas
    /// (a counter drifts the moment a scroll clamps at the top of the scrollback).
    ///
    /// This matters because a TUI's scrollback does not look like a transcript: Claude
    /// Code repaints by erasing and reprinting whole frames, so history is full of
    /// blank bands and orphaned frames. Parked there with no marker on screen, the
    /// terminal reads as broken — "cut off" — rather than as scrolled.
    var isViewingScrollback: Bool { grid.rows > 0 && !grid.live }

    private static let scrollbackBadgeText = "↓ jump to live"

    private var scrollbackBadgeAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
         .foregroundColor: BoardTheme.textMuted]
    }

    /// The pill's rect, bottom-right of the surface. Computed on demand so the hit
    /// test and the drawing can never disagree about where it is.
    func scrollbackBadgeRect() -> NSRect {
        let size = (Self.scrollbackBadgeText as NSString)
            .size(withAttributes: scrollbackBadgeAttributes)
        let width = size.width + 20
        let height = size.height + 8
        return NSRect(x: bounds.maxX - inset - width, y: bounds.maxY - inset - height,
                      width: width, height: height)
    }

    private func drawScrollbackBadge() {
        guard isViewingScrollback else { return }
        let rect = scrollbackBadgeRect()
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2,
                                yRadius: rect.height / 2)
        BoardTheme.cardFillRaised.setFill()
        pill.fill()
        BoardTheme.cardStrokeStrong.setStroke()
        pill.lineWidth = 1
        pill.stroke()
        let text = Self.scrollbackBadgeText as NSString
        let size = text.size(withAttributes: scrollbackBadgeAttributes)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                  withAttributes: scrollbackBadgeAttributes)
    }

    /// Snap the viewport back onto the live screen. Every keystroke does this, and so
    /// does clicking the pill — the two ways out of history.
    private func returnToLiveBottom() {
        session.terminal.scrollViewportToBottom()
        pendingScroll = 0
        // `grid` still holds the pre-scroll viewport, so this asks "were we in
        // history?". Only then is a full repaint owed; the common case — a keystroke
        // while already live — stays on the cheap per-row damage diff.
        guard isViewingScrollback else { return }
        scrollFraction = 0
        requestRefresh(.viewport)
    }

    /// Put the previous/next user prompt at the top of the viewport. Marks come
    /// from the rendered transcript (``TranscriptMarks``), the position from the
    /// emulator's own viewport offset. Past the last prompt, "next" returns to
    /// the live screen; past the first, "previous" beeps and stays.
    func jumpToUserPrompt(previous: Bool) {
        let terminal = session.terminal
        guard !terminal.alternateScreenActive, let lines = try? terminal.lines() else { return }
        let marks = TranscriptMarks.userPromptRows(
            in: lines, cursorRow: terminal.scrollbackRows + terminal.cursorRow)
        let offset = terminal.viewportOffset
        let target = previous ? marks.last(where: { $0 < offset }) : marks.first(where: { $0 > offset })
        guard let target else {
            if previous { NSSound.beep() } else { returnToLiveBottom() }
            return
        }
        pendingScroll = 0
        scrollFraction = 0
        terminal.scrollViewport(delta: target - offset)
        requestRefresh(.viewport)
    }

    // MARK: - Colour helpers

    /// The lowest text/background contrast ratio we tolerate before lifting the
    /// foreground (see ``TerminalSurface/legibleFg(_:on:)``). Tuned to rescue dim
    /// shell autosuggestions / SGR-faint text without repainting already-readable
    /// output — the pixel result is a human sign-off, this is the knob.
    private static let minimumTextContrast = 3.5

    private var nsColorCache: [RGB: NSColor] = [:]
    private struct GlyphKey: Hashable {
        let color: RGB
        let style: TerminalCellStyle
    }
    private var glyphAttrsCache: [GlyphKey: [NSAttributedString.Key: Any]] = [:]
    private var cachedTerminalBackground: RGB?

    private func glyphAttrs(
        fg: RGB?, bg: RGB? = nil, style: TerminalCellStyle = .plain
    ) -> [NSAttributedString.Key: Any] {
        let base = fg ?? grid.defaultFg
        guard let base else {
            return [.font: font, .foregroundColor: BoardTheme.termFg,
                    .ligature: 0, .kern: 0]
        }
        let adjusted = ContrastColor.adjusted(
            base, against: bg ?? terminalBackgroundRGB(),
            minimumRatio: Self.minimumTextContrast)
        let key = GlyphKey(color: adjusted, style: style)
        if let cached = glyphAttrsCache[key] { return cached }
        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }
        let styledFont = traits.isEmpty ? font : NSFontManager.shared.convert(font, toHaveTrait: traits)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: styledFont, .foregroundColor: nsColor(adjusted), .ligature: 0, .kern: 0,
        ]
        if style.underline != 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        glyphAttrsCache[key] = attrs
        return attrs
    }

    /// Resolve a cell's foreground to an NSColor, first lifting it to meet the
    /// minimum contrast against its effective background so faint suggestions become
    /// easy to spot. `nil` fg/bg fall back to the terminal defaults.
    private func legibleFg(_ fg: RGB?, on bg: RGB?) -> NSColor {
        let base = fg ?? grid.defaultFg
        guard let base else { return BoardTheme.termFg }
        let adjusted = ContrastColor.adjusted(
            base, against: bg ?? terminalBackgroundRGB(),
            minimumRatio: Self.minimumTextContrast)
        return nsColor(adjusted)
    }

    /// The surface's default background as an RGB, resolved for the *current*
    /// appearance (this runs inside `draw(_:)`, where the dynamic colour resolves to
    /// light/dark correctly) so the contrast maths use the real backdrop.
    private func terminalBackgroundRGB() -> RGB {
        if let cachedTerminalBackground { return cachedTerminalBackground }
        guard let srgb = BoardTheme.termBg.usingColorSpace(.sRGB) else { return RGB(r: 0, g: 0, b: 0) }
        let resolved = RGB(r: UInt8(srgb.redComponent * 255),
                           g: UInt8(srgb.greenComponent * 255),
                           b: UInt8(srgb.blueComponent * 255))
        cachedTerminalBackground = resolved
        return resolved
    }

    private func nsColor(_ c: RGB) -> NSColor {
        if let cached = nsColorCache[c] { return cached }
        let color = NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                            blue: CGFloat(c.b) / 255, alpha: 1)
        nsColorCache[c] = color
        return color
    }

    /// Test seam: the exact fg the draw path would paint for a cell (fg on bg), so a
    /// test can prove the surface routes through the contrast lift — the drawn pixels
    /// themselves stay a human sign-off.
    func resolvedForegroundForTesting(fg: RGB?, bg: RGB?) -> NSColor {
        legibleFg(fg, on: bg)
    }

    /// Test seams (item 9): install a deterministic screen and hit-test links the
    /// way the ⌘-click path does, without racing a live pty read.
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    /// The grid the last refresh painted — what is on screen, not what the emulator holds.
    var gridForTesting: TerminalGrid { grid }

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    func installGridForTesting(_ snapshot: TerminalGrid) {
        grid = snapshot
        syncRowLayers(changedFrom: nil)
        overlay.needsDisplay = true
    }

    /// The row image cache and the layer stack behind the viewport — lets a test
    /// prove a scroll is pointer swaps (hits), not a repaint (misses).
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var rowCacheForTesting: TerminalRowCache { rowCache }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var rowHostForTesting: TerminalRowLayerHost { rowHost }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var scrollFractionForTesting: CGFloat { scrollFraction }
    /// Run one display-link frame by hand (headless tests have no link).
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    @discardableResult
    func displayFrameForTesting() -> Bool { displayFrame() }

    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    func linkForTesting(atCol col: Int, row: Int) -> TerminalLink? {
        links(in: row).first { $0.columns.contains(col) }
    }

    /// The centre of a grid cell in this view's coords — lets the interaction test
    /// aim a real event without duplicating the font-metric math.
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    func cellCenterForTesting(col: Int, row: Int) -> NSPoint {
        NSPoint(x: inset + (CGFloat(col) + 0.5) * cellSize.width,
                y: rowTop(row) + 0.5 * cellSize.height)
    }

    private struct GridPoint: Equatable {
        var row: Int
        var col: Int
    }

    private func gridPoint(at point: NSPoint) -> GridPoint {
        guard grid.rows > 0, grid.cols > 0 else { return GridPoint(row: 0, col: 0) }
        let col = max(0, min(grid.cols - 1, Int((point.x - inset) / cellSize.width)))
        let row = max(0, min(grid.rows - 1, Int((point.y - inset) / cellSize.height + scrollFraction)))
        return GridPoint(row: row, col: col)
    }

    private func orderedSelection() -> (start: GridPoint, end: GridPoint)? {
        guard let a = selectionAnchor, let b = selectionFocus, a != b else { return nil }
        if a.row < b.row || (a.row == b.row && a.col <= b.col) { return (a, b) }
        return (b, a)
    }

    private func drawSelection() {
        guard let range = orderedSelection() else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        rowHost.frame.clip()   // a shifted selection row must not bleed into the padding
        BoardTheme.brand.withAlphaComponent(0.32).setFill()
        for row in range.start.row...range.end.row {
            let startCol = row == range.start.row ? range.start.col : 0
            let endCol = row == range.end.row ? range.end.col : grid.cols - 1
            guard endCol >= startCol else { continue }
            NSRect(
                x: inset + CGFloat(startCol) * cellSize.width,
                y: rowTop(row),
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
        overlay.needsDisplay = true
    }

    private func autoscrollSelectionIfNeeded(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < inset {
            pendingScroll += 1
            requestRefresh(.viewport)
        } else if point.y > bounds.maxY - inset {
            pendingScroll -= 1
            requestRefresh(.viewport)
        }
    }
}
