import AppKit
import SichCore

/// The operator's own instrument under the provider gauges: the ring, the card it is
/// counting toward, the day's tally, and — when the board has advice — one line of
/// it. Everything the ring area says comes from ``PomodoroState`` plus a few words
/// the shell looks up (card titles); the dock holds no timer of its own.
///
/// Updated in place once a second (`render`): the fields are created once and only
/// their text / visibility changes, so a tick costs a handful of label updates, not a
/// rebuild. Built from label fields and custom-drawn layers like the rest of the quota
/// panel — stock controls don't composite reliably on this hand-painted surface.
@MainActor
final class PomodoroDock: NSView {
    /// What the dock needs from the shell beyond the engine state.
    struct Context: Equatable {
        /// The tagged card's title, when it still exists.
        var cardTitle: String?
        var hint: PomodoroHint?
        /// Compact: the bottom dock — a smaller ring, no "on <card>" line.
        var compact = false
    }

    var onToggle: (() -> Void)?
    var onRestNow: (() -> Void)?
    var onHint: ((PomodoroHint) -> Void)?

    private let compact: Bool
    let ring: PomodoroRingView
    private let onCard = NSTextField(labelWithString: "")
    private let dots = NSTextField(labelWithString: "")
    private let tally = NSTextField(labelWithString: "")
    private let restNow = ClickableLabel()
    private let hintField = ClickableLabel()
    private let heldField = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var currentHint: PomodoroHint?

    init(compact: Bool) {
        self.compact = compact
        ring = PomodoroRingView(diameter: compact ? 112 : 168, showsPhase: !compact)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        ring.onClick = { [weak self] in self?.onToggle?() }
        restNow.onClick = { [weak self] in self?.onRestNow?() }
        hintField.onClick = { [weak self] in
            guard let self, let hint = currentHint else { return }
            onHint?(hint)
        }
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(
            top: compact ? QuotaLayout.headerTop : 0, left: QuotaLayout.outerInset,
            bottom: QuotaLayout.outerInset, right: QuotaLayout.outerInset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.addArrangedSubview(ring)

        configure(onCard, font: .systemFont(ofSize: 13.5, weight: .medium), color: BoardTheme.textPrimary)
        onCard.alignment = .center
        onCard.lineBreakMode = .byTruncatingTail
        onCard.isHidden = compact
        addFullWidth(onCard)
        stack.setCustomSpacing(8, after: onCard)

        let you = NSTextField(labelWithString: "You")
        configure(you, font: .systemFont(ofSize: 13, weight: .semibold), color: BoardTheme.textPrimary)
        configure(dots, font: .systemFont(ofSize: 12), color: BoardTheme.textPrimary.withAlphaComponent(0.45))
        configure(tally, font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                  color: BoardTheme.textPrimary.withAlphaComponent(0.72))
        tally.alignment = .right
        tally.lineBreakMode = .byTruncatingTail
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)
        let under = NSStackView(views: [you, dots, spring, tally])
        under.orientation = .horizontal
        under.alignment = .centerY
        under.spacing = 8
        addFullWidth(under)

        configure(restNow, font: BoardTheme.mono, color: BoardTheme.textPrimary.withAlphaComponent(0.62))
        restNow.stringValue = "rest now ›"
        restNow.alignment = .right
        restNow.toolTip = "End this pomodoro now and rest"
        addFullWidth(restNow)

        configure(hintField, font: .systemFont(ofSize: 13), color: BoardTheme.attention)
        hintField.alignment = .center
        hintField.lineBreakMode = .byWordWrapping
        hintField.maximumNumberOfLines = 3
        addFullWidth(hintField)

        configure(heldField, font: .systemFont(ofSize: 13), color: BoardTheme.textPrimary.withAlphaComponent(0.78))
        heldField.alignment = .center
        heldField.lineBreakMode = .byWordWrapping
        heldField.maximumNumberOfLines = 2
        addFullWidth(heldField)
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: QuotaLayout.outerInset),
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -QuotaLayout.outerInset),
        ])
    }

    private func configure(_ field: NSTextField, font: NSFont, color: NSColor) {
        field.font = font
        field.textColor = color
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.yieldWidthToWindow()
    }

    // MARK: - Render

    /// The four cycle dots: ● done, ◐ the one running, ○ still to come.
    static func dotsText(_ state: PomodoroState) -> String {
        let done = state.completed % PomodoroConstants.perCycle
        let current = state.phase == .work ? 1 : 0
        return (0..<PomodoroConstants.perCycle).map { index in
            index < done ? "●" : (index == done && current == 1) ? "◐" : "○"
        }.joined(separator: " ")
    }

    /// The line under the ring: which card the minutes land on, or what the ring
    /// would do if started.
    static func onCardText(_ state: PomodoroState, cardTitle: String?) -> (lead: String, title: String?, tail: String) {
        if state.phase == .work || state.awaitingReply {
            guard let cardTitle else { return ("no card — drill in to tag one", nil, "") }
            let more = state.touched.count - 1
            return ("on ", cardTitle, more > 0 ? " · +\(more) more" : "")
        }
        if state.isBreak { return ("agents keep working", nil, "") }
        return ("tags the card you're in", nil, "")
    }

    func render(state: PomodoroState, context: Context) {
        currentHint = context.hint
        ring.apply(state)

        let parts = Self.onCardText(state, cardTitle: context.cardTitle)
        let muted = BoardTheme.textPrimary.withAlphaComponent(0.62)
        let line = NSMutableAttributedString(
            string: parts.lead,
            attributes: [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: muted])
        if let title = parts.title {
            line.append(NSAttributedString(
                string: title,
                attributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
                             .foregroundColor: BoardTheme.textPrimary]))
            line.append(NSAttributedString(
                string: parts.tail,
                attributes: [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: muted]))
        }
        onCard.attributedStringValue = line

        dots.attributedStringValue = Self.dotsAttributed(state)
        dots.toolTip = "\(state.completed) pomodoros today"
        tally.stringValue = "\(state.completed) today · \(PomodoroFormat.minutes(state.focusToday))"

        restNow.isHidden = state.phase != .work || state.awaitingReply
        hintField.isHidden = context.hint == nil
        hintField.stringValue = context.hint?.text ?? ""
        let held = state.held.count
        heldField.isHidden = held == 0
        heldField.stringValue = "\(held) will need you after this \(state.isBreak ? "break" : "pomodoro")"
    }

    private static func dotsAttributed(_ state: PomodoroState) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, glyph) in dotsText(state).split(separator: " ").enumerated() {
            let filled = glyph != "○"
            text.append(NSAttributedString(
                string: String(glyph) + (index == PomodoroConstants.perCycle - 1 ? "" : " "),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .kern: 2,
                    .foregroundColor: filled ? BoardTheme.textFaint : BoardTheme.textPrimary.withAlphaComponent(0.45),
                ]))
        }
        return text
    }

    // Test seams.
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var onCardTextForTesting: String { onCard.attributedStringValue.string }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var tallyForTesting: String { tally.stringValue }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var restNowForTesting: ClickableLabel { restNow }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var hintForTesting: ClickableLabel { hintField }
    // periphery:ignore - test-only seam (scan runs with exclude_tests)
    var heldTextForTesting: String? { heldField.isHidden ? nil : heldField.stringValue }
}

/// A label that is also a click target — the "rest now ›" control and the advice
/// line. Same single layer-free text field; the pointer and `mouseDown` are the only
/// additions (a non-editable label never starts editing on click).
@MainActor
final class ClickableLabel: NSTextField {
    var onClick: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
