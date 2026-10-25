import AppKit
import SichCore
import Testing

@testable import SichApp

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

    // MARK: - Portrait windows: quota under the board, DONE narrowed

    @Test("a landscape window keeps the quota panel on the trailing edge")
    func landscapeDocksTrailing() {
        #expect(QuotaLayout.dock(forContentSize: NSSize(width: 1400, height: 860)) == .trailing)
        #expect(QuotaLayout.dock(forContentSize: NSSize(width: 900, height: 900)) == .trailing)
    }

    @Test("a portrait window docks the quota panel at the bottom, as many cards as fit")
    func portraitDocksBottom() {
        // 264pt cards + 12pt gaps inside 12pt insets: three fit 1080, two fit 640.
        #expect(QuotaLayout.dock(forContentSize: NSSize(width: 1080, height: 1884))
            == .bottom(columns: 3))
        #expect(QuotaLayout.dock(forContentSize: NSSize(width: 640, height: 900))
            == .bottom(columns: 2))
    }

    @Test("a bottom-docked panel splits the usage table across cards and loses no gauge")
    func bottomDockSplitsUsageTable() {
        func headers(in view: NSView) -> Int {
            let own = (view as? NSTextField)?.stringValue == "WEEKLY" ? 1 : 0
            return view.subviews.reduce(own) { $0 + headers(in: $1) }
        }
        let gauges = QuotaProjection.gauges(from: QuotaSeed.demo)
        let side = QuotaPanel()
        side.render(gauges: gauges)
        let strip = QuotaPanel()
        strip.dock = .bottom(columns: 3)
        strip.render(gauges: gauges)

        #expect(headers(in: side) == 1)
        #expect(headers(in: strip) == 2)
        #expect(strip.rows.map(\.gauge.id) == side.rows.map(\.gauge.id))
    }

    @Test("a narrow DONE column gives its width to the live columns")
    func narrowDoneYieldsWidth() throws {
        func columnWidth(_ view: BoardView, _ group: BoardView.ColumnGroup) throws -> CGFloat {
            let scroll = try #require(view.cellForTesting(group)?.enclosingScrollView)
            return try #require(scroll.superview?.superview).frame.width
        }
        let view = BoardView(
            frame: NSRect(x: 0, y: 0, width: 1080, height: 1600),
            defaults: try #require(UserDefaults(suiteName: "narrow-done-\(UUID())")))
        view.layoutSubtreeIfNeeded()
        let evenWorking = try columnWidth(view, .working)

        view.isDoneNarrow = true
        view.layoutSubtreeIfNeeded()
        let working = try columnWidth(view, .working)
        let done = try columnWidth(view, .done)
        #expect(working > evenWorking)
        #expect(abs(done - working * BoardView.narrowDoneRatio) < 1)
    }

    @Test("the shell puts the quota strip under a full-width board in a portrait window")
    func portraitShellStacksBoardOverQuota() {
        let shell = BoardShell(seeds: [])
        let root = shell.buildContentForTesting(size: NSSize(width: 1080, height: 1884))
        #expect(shell.quota.dock == .bottom(columns: 3))
        #expect(shell.boardView.isDoneNarrow)
        #expect(shell.boardView.frame.width == root.frame.width)
        #expect(shell.quota.frame.width == root.frame.width)
        #expect(shell.quota.frame.height > 0)
        #expect(shell.quota.frame.height <= root.frame.height * 0.4)
        // Root is unflipped: the strip sits at the bottom, the board on top of it.
        #expect(shell.quota.frame.minY == 0)
        #expect(shell.boardView.frame.minY == shell.quota.frame.maxY)
    }

    @Test("the shell keeps the quota column beside the board in a landscape window")
    func landscapeShellKeepsQuotaColumn() {
        let shell = BoardShell(seeds: [])
        let root = shell.buildContentForTesting()
        #expect(shell.quota.dock == .trailing)
        #expect(!shell.boardView.isDoneNarrow)
        #expect(shell.quota.frame.width == QuotaLayout.panelWidth)
        #expect(shell.quota.frame.maxX == root.frame.width)
        #expect(shell.boardView.frame.maxX == shell.quota.frame.minX)
    }

    // MARK: - Column scrolling

    private func card(_ n: Int) -> BoardCard {
        BoardCard(
            sessionID: "s\(n)", title: "task-\(n)", projectDir: "/Users/x/p",
            agent: .claude, state: .running)
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
