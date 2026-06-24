import AppKit
import GhostlingCore

/// A thin AppKit view that renders one ``PTYSession``'s libghostty-vt screen and
/// routes key events back into it. Single responsibility: one surface = one PTY.
/// There is **no** product logic here (no board, no quota) — it only renders the
/// emulator grid and forwards keystrokes, leaning on `Terminal`/`PTYSession`.
///
/// Rendering is a simple monospaced draw of `Terminal.lines()` — legible and
/// interactive, not a GPU glyph renderer (sufficient for this Phase 01 slice).
@MainActor
public final class TerminalSurface: NSView {
    private let session: PTYSession
    private var readSource: DispatchSourceRead?
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    /// Escape policy. When set, an `Esc` keypress is offered here *before* it is
    /// forwarded to the PTY; returning `true` means "this surface is hosted (e.g.
    /// drilled-in) and Esc means leave" so Esc is consumed, NOT sent to the child.
    /// `nil` / `false` ⇒ Esc reaches the session as usual, so a real interactive
    /// agent (a later task) can still receive it. This is the deterministic seam:
    /// the surface is the first responder, so its `keyDown` is exactly where Esc
    /// arrives — a button `keyEquivalent` is shadowed by it and cannot be relied on.
    var onEscape: (() -> Bool)?
    /// Cache of the last rendered lines; refreshed on PTY output.
    private var lines: [String] = []
    /// A dim end-of-session banner appended once the session terminates, so a
    /// finished window reads as *ended* rather than *hung*. `nil` while live.
    private var endBanner: String?

    public init(session: PTYSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
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

    // MARK: - PTY read loop

    /// Start reading the PTY on the main run loop so the emulator screen stays
    /// live without screen-scraping. Idempotent.
    public func startReading() {
        guard readSource == nil, session.masterFD >= 0 else { return }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: session.masterFD, queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.onReadable() }   // queued on .main
        }
        source.resume()
        readSource = source
    }

    public func stopReading() {
        readSource?.cancel()
        readSource = nil
    }

    private func onReadable() {
        let n = session.pump()
        if n > 0 { refresh() } else { stopReading() }   // 0 = EOF: child gone
    }

    private func refresh() {
        lines = (try? session.terminal.lines()) ?? lines
        needsDisplay = true
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

    public override func keyDown(with event: NSEvent) {
        guard let input = Self.keyInput(from: event) else {
            super.keyDown(with: event)
            return
        }
        // Esc is offered to the host first. If it claims it (drill-in → back to the
        // board), it is consumed here and never reaches the child. Otherwise it
        // flows to the PTY like any other key.
        if case .escape = input, onEscape?() == true { return }
        session.send(KeyEncoder.bytes(for: input))
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
        NSColor.black.setFill()
        dirtyRect.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let lineHeight = font.boundingRectForFont.height + 2
        for (i, line) in lines.enumerated() {
            let origin = NSPoint(x: 6, y: 6 + CGFloat(i) * lineHeight)
            (line as NSString).draw(at: origin, withAttributes: attrs)
        }
        drawEndBanner(after: lines.count, lineHeight: lineHeight)
    }

    /// Draw the dim end banner one blank line below the last terminal row.
    private func drawEndBanner(after rowCount: Int, lineHeight: CGFloat) {
        guard let endBanner else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.systemGray,
        ]
        let origin = NSPoint(x: 6, y: 6 + CGFloat(rowCount + 1) * lineHeight)
        (endBanner as NSString).draw(at: origin, withAttributes: attrs)
    }
}
