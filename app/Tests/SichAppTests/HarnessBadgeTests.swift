import AppKit
import Foundation
import Testing

@testable import SichApp
@testable import SichCore

/// The harness mark replaces textual "Claude Code"/"Codex" labels with a tinted
/// silhouette. These bind it to its real render sites
/// (a green badge type nobody mounts is the "green but unreachable" trap).
@MainActor
@Suite("Harness badge")
struct HarnessBadgeTests {

    @Test("every harness has a real brand mark, and the full name survives as tooltip")
    func brandMarkWithTooltip() {
        // Each harness resolves to a distinct, mountable brand image (not a unicode glyph).
        let marks = CardAgent.allCases.map { BoardTheme.agentMark($0) }
        #expect(marks.allSatisfy { $0 != nil })
        #expect(Set(marks.map { ObjectIdentifier($0!) }).count == CardAgent.allCases.count)

        let badge = HarnessBadge(agent: .claude)
        #expect(badge.agent == .claude)
        #expect(badge.toolTip == "Claude Code")
        #expect(badge.intrinsicContentSize == NSSize(width: 16, height: 16))
        #expect(badge.layer?.borderWidth == 0)
        #expect(badge.layer?.backgroundColor == nil)
        badge.set(agent: .codex)
        #expect(badge.agent == .codex)
        #expect(badge.toolTip == "Codex")
    }

    @Test("the tint follows the logo alpha instead of painting its bounding square")
    func markTintPreservesTransparentCorners() throws {
        let badge = HarnessBadge(agent: .claude)
        badge.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        badge.bounds.fill()
        badge.draw(badge.bounds)

        for point in [(1, 1), (14, 1), (1, 14), (14, 14)] {
            let color = try #require(rep.colorAt(x: point.0, y: point.1))
            #expect(color.redComponent > 0.95 && color.greenComponent > 0.95
                    && color.blueComponent > 0.95)
        }
    }

    @Test("a board card's header carries the badge instead of a textual agent name")
    func sessionCardHeaderCarriesBadge() throws {
        let card = BoardCard(
            sessionID: "s-1", title: "Fix login", projectDir: "/tmp/p",
            agent: .codex, flow: .b, state: .running
        )
        let view = SessionCard(card: card)
        let badge = try #require(allSubviews(of: view).compactMap { $0 as? HarnessBadge }.first)
        #expect(badge.agent == .codex)
        let labels = allSubviews(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(!labels.contains { $0.contains("Codex") }, "the name moved into the badge tooltip")
        #expect(!labels.contains("terminal"), "the default flow carries no text label")
    }

    @Test("only an autonomous card is flow-labelled — a small 'auto' marker")
    func autonomousCardCarriesAutoMarker() {
        let auto = SessionCard(card: BoardCard(
            sessionID: "s-2", title: "Saha run", projectDir: "/tmp/p",
            agent: .claude, flow: .a, state: .running
        ))
        let labels = allSubviews(of: auto).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("auto"), "the exception flow is the one that gets labelled")
    }

    @Test("working shows the current interval with a pulsing live-activity mark")
    func workingDurationFooter() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let working = SessionCard(card: BoardCard(
            sessionID: "timer", title: "Timed task", projectDir: "/tmp/p",
            agent: .codex, flow: .b, state: .running,
            workingSince: now.addingTimeInterval(-(7 * 60)),
            accumulatedWorkingTime: 2 * 3_600
        ), now: { now })

        let timer = try #require(allSubviews(of: working).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "task-duration" })
        #expect(timer.stringValue == "7m", "WORKING shows this interval, not the global total")
        let pulse = try #require(allSubviews(of: working).compactMap { $0 as? NSImageView }
            .first { $0.identifier?.rawValue == "duration-working-pulse" })
        #expect(pulse.contentTintColor == BoardTheme.stateColor(.running))
        #expect(pulse.layer?.animation(forKey: "working-heartbeat") != nil
                || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let face = try #require(working.subviews.compactMap { $0 as? NSStackView }.first)
        let footer = try #require(face.arrangedSubviews.last)
        #expect(allSubviews(of: footer).contains(timer),
                "the duration lives in the card's bottom footer row")
    }

    @Test("an unstarted task does not show an empty cumulative timer")
    func zeroDurationIsHiddenUntilTaskStarts() {
        for state in [CardState.idle, .waitingForInput, .done] {
            let unstarted = SessionCard(card: BoardCard(
                sessionID: "unstarted-\(state)", title: "Fresh task", projectDir: "/tmp/p",
                agent: .codex, flow: .b, state: state
            ))
            #expect(!allSubviews(of: unstarted).contains {
                $0.identifier?.rawValue == "task-duration"
            })
        }
    }

    @Test("a newly started working interval is visible even before its first minute")
    func activeZeroMinuteIntervalIsVisible() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let started = SessionCard(card: BoardCard(
            sessionID: "just-started", title: "Fresh task", projectDir: "/tmp/p",
            agent: .codex, flow: .b, state: .running, workingSince: now
        ), now: { now })
        let timer = try #require(allSubviews(of: started).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "task-duration" })
        #expect(timer.stringValue == "0m")
        #expect(allSubviews(of: started).contains {
            $0.identifier?.rawValue == "duration-working-pulse"
        })
    }

    @Test("other columns show cumulative active work with a clock")
    func cumulativeDurationOutsideWorking() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let waiting = SessionCard(card: BoardCard(
            sessionID: "waiting", title: "Waiting task", projectDir: "/tmp/p",
            agent: .codex, flow: .b, state: .waitingForInput,
            accumulatedWorkingTime: 2 * 3_600 + 7 * 60
        ), now: { now })
        let timer = try #require(allSubviews(of: waiting).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "task-duration" })
        #expect(timer.stringValue == "2h 07m")
        #expect(allSubviews(of: waiting).contains {
            $0.identifier?.rawValue == "duration-clock"
        })
    }

    @Test("working duration formatting stays compact from minutes through days")
    func workingDurationFormatting() {
        #expect(SessionCard.formatDuration(0) == "0m")
        #expect(SessionCard.formatDuration(59 * 60) == "59m")
        #expect(SessionCard.formatDuration(64 * 60) == "1h 04m")
        #expect(SessionCard.formatDuration((2 * 24 + 3) * 3_600) == "2d 3h")
    }

    @Test("neutral and done cards use surface separation, while attention and focus own edges")
    func cardEdgesAreSemantic() {
        let neutral = sessionCard(state: .running)
        #expect(neutral.layer?.borderWidth == 0)
        #expect((neutral.layer?.shadowOpacity ?? 0) > 0)

        let done = sessionCard(state: .done)
        #expect(done.layer?.borderWidth == 0, "the check row already communicates done")

        let waiting = sessionCard(state: .waitingForInput)
        #expect(waiting.layer?.borderWidth == 1)
        #expect(waiting.layer?.borderColor != nil)

        let blocked = sessionCard(state: .blocked)
        #expect(blocked.layer?.borderWidth == 1)
        #expect(blocked.layer?.borderColor != nil)

        neutral.setKeyboardFocus(true)
        #expect(neutral.layer?.borderWidth == 2)
        neutral.setKeyboardFocus(false)
        #expect(neutral.layer?.borderWidth == 0)
    }

    @Test("board chrome is a filled control without a bezel stroke")
    func boardChromeUsesFillNotOutline() {
        let button = QuietBoardButton(title: "Backlog")
        #expect(!button.isBordered)
        #expect(button.layer?.borderWidth == 0)
        #expect(button.layer?.backgroundColor != nil)
    }

    private func sessionCard(state: CardState) -> SessionCard {
        SessionCard(card: BoardCard(
            sessionID: UUID().uuidString, title: "Task", projectDir: "/tmp/p",
            agent: .claude, flow: .b, state: state
        ))
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}
