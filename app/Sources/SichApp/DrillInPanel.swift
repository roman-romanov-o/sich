import AppKit
import SichCore

/// The drill-in surface (US-002): when a card is selected, this panel takes over
/// the full window (Altitude-1) hosting that session's embedded ``TerminalSurface``
/// — in-app focus, not an OS window jump (DD-001).
///
/// It is the terminal and nothing else. Which task this is and the way back live
/// in the window's own titlebar (``TaskTitlebar``), which takes the terminal's paper
/// while a card is open, so the titlebar and the terminal read as one surface.
/// Single responsibility: present one focused session and a way back.
@MainActor
final class DrillInPanel: NSView {
    /// Invoked when the operator returns to the board (US-002 AC#2).
    var onClose: (() -> Void)?
    /// Invoked with the focused card's id when its terminal submits a `!` line.
    var onShellEscapeSubmit: ((UUID) -> Void)?
    /// Enter sent a typed line in the focused card's terminal.
    var onSubmit: ((UUID) -> Void)?

    private var surface: TerminalSurface?

    /// The mounted terminal, so an E2E can read what the operator actually sees.
    var surfaceForTesting: TerminalSurface? { surface }
    private var focusedCard: BoardCard?
    private var terminalFontSize: CGFloat = 20

    /// Item 8 (18.08): true only in the production shell — drill-in surfaces then
    /// teach TerminalGeometry their settled grid so future spawns are born pre-sized.
    /// Tests and E2E captures leave it false and never touch the real defaults.
    var teachesGeometry = false

    /// The gap between the window edge and the terminal's paper, left and right. The
    /// surface keeps its own 9pt text inset inside it.
    static let sideMargin: CGFloat = 6

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        themedBackground = BoardTheme.termBg
    }

    required init?(coder: NSCoder) { nil }

    /// Focus a card's session: show its live embedded terminal, ready for input
    /// (US-002 AC#1). The previous surface is detached first so only the focused
    /// terminal is foreground-rendered (US-002 edge case #2 / TC-E2E-007).
    func focus(card: BoardCard, pty: PTYSession, terminalFontSize: CGFloat = 20) {
        focusedCard = card
        self.terminalFontSize = terminalFontSize
        detachSurface()
        let surface = TerminalSurface(session: pty, fontSize: terminalFontSize)
        surface.teachesGeometry = teachesGeometry
        surface.workingDirectory = card.projectDir   // relative file links resolve here
        // Esc belongs to the child (Claude Code interrupt / edit), so "back to board"
        // is ⌘[ — routed via the surface's `performKeyEquivalent`. The titlebar's
        // "Board" button is the other way back.
        surface.onBack = { [weak self] in self?.goBack(); return true }
        surface.onShellEscapeSubmit = { [weak self] in self?.onShellEscapeSubmit?(card.id) }
        surface.onSubmit = { [weak self] in self?.onSubmit?(card.id) }
        mount(surface)
        surface.startReading()
        window?.makeFirstResponder(surface)   // ready for typed input
        self.surface = surface
    }

    private func mount(_ surface: TerminalSurface) {
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideMargin),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideMargin),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func detachSurface() {
        surface?.stopReading()
        surface?.removeFromSuperview()
        surface = nil
    }

    /// Is there a typed, unsent line in the focused terminal right now?
    var hasUnsentInput: Bool { surface?.hasUnsentInput ?? false }

    /// Give the keyboard back to the terminal (after an overlay had it).
    func reclaimKeyboard() {
        guard let surface else { return }
        window?.makeFirstResponder(surface)
    }

    /// The child died while drilled in: the surface shows its end-of-session banner,
    /// so the terminal never reads as hung.
    func markEnded(_ disposition: SessionDisposition) {
        surface?.markEnded(disposition)
    }

    func updateTerminalFontSize(_ size: CGFloat) {
        terminalFontSize = size
        guard let card = focusedCard, let pty = surface?.ptySession else { return }
        focus(card: card, pty: pty, terminalFontSize: size)
    }

    /// Return to the board (US-002 AC#2). Internal so the interaction is driven by a
    /// real view-level test, not just the `BoardSelection` value type.
    @objc func goBack() {
        detachSurface()
        focusedCard = nil
        onClose?()
    }
}
