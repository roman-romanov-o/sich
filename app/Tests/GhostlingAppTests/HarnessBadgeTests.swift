import AppKit
import Foundation
import Testing

@testable import GhostlingApp
@testable import GhostlingCore

/// The harness badge replaces textual "Claude Code"/"Codex" labels with a glyph
/// chip in the harness's colour. These bind the badge to its real render sites
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
        badge.set(agent: .codex)
        #expect(badge.agent == .codex)
        #expect(badge.toolTip == "Codex")
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

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}
