import AppKit
import GhostlingCore
import Testing

@testable import GhostlingApp

/// The small-screen round: board type auto-shrinks with the window width and
/// every column scrolls instead of clipping its cards.
@MainActor
struct ResponsiveBoardTests {
    // MARK: - Responsive type scale (pure curve)

    @Test("full design width and anything wider keep scale 1.0")
    func fullWidthIsUnscaled() {
        #expect(BoardTheme.responsiveScale(forContentWidth: 1400) == 1.0)
        #expect(BoardTheme.responsiveScale(forContentWidth: 2200) == 1.0)
    }

    @Test("narrow windows shrink proportionally, quantized to 0.05 steps")
    func narrowWidthShrinksQuantized() {
        // 1330/1400 = 0.95 exactly; 1288/1400 = 0.92 → nearest step 0.9.
        #expect(BoardTheme.responsiveScale(forContentWidth: 1330) == 0.95)
        #expect(BoardTheme.responsiveScale(forContentWidth: 1288) == 0.90)
    }

    @Test("the shrink floors at 0.85 no matter how narrow the window gets")
    func shrinkFloorsAtPointEightFive() {
        #expect(BoardTheme.responsiveScale(forContentWidth: 700) == 0.85)
        #expect(BoardTheme.responsiveScale(forContentWidth: BoardShell.minContentSize.width) == 0.85)
    }

    // MARK: - Column scrolling

    private func card(_ n: Int) -> BoardCard {
        BoardCard(
            sessionID: "s\(n)", title: "task-\(n)", projectDir: "/Users/x/p",
            agent: .claude, flow: .b, state: .running)
    }

    @Test("every board column cell lives inside a scroll view")
    func columnsAreScrollable() throws {
        let view = BoardView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.render(cards: [card(0)])
        view.layoutSubtreeIfNeeded()
        for group in BoardView.ColumnGroup.allCases {
            let cell = try #require(view.cellForTesting(group))
            #expect(cell.enclosingScrollView != nil, "\(group) column must scroll")
        }
    }

    @Test("a column overfilled with cards scrolls: content grows past the viewport")
    func overfilledColumnContentExceedsViewport() throws {
        // A short board with many working cards — pre-scroll this clipped.
        let view = BoardView(frame: NSRect(x: 0, y: 0, width: 1280, height: 400))
        view.render(cards: (0..<12).map(card))
        view.layoutSubtreeIfNeeded()

        let cell = try #require(view.cellForTesting(.working))
        let scroll = try #require(cell.enclosingScrollView)
        #expect(cell.frame.height > scroll.contentView.bounds.height,
                "12 cards must overflow a 400pt board and become scrollable content")
    }
}
