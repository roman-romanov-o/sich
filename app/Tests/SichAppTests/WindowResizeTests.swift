import AppKit
import SichCore
import Testing

@testable import SichApp

/// The un-resizable-window bug: AppKit resolves a user's resize drag at layout
/// priority 510 and the window's "keep my size" preference at 500, so any board
/// label left at the default 750 horizontal compression resistance becomes an
/// unbreakable window-width minimum. The equal-width column constraint then
/// multiplies the single worst card title across all five columns — a real board
/// wedged at 2053pt on an 1800pt screen, immune to edge-drag and `setFrame`.
/// These tests bind the fix to the real failure: a window hosting the real board
/// content, resized below the cards' natural width, must STAY at the size it was
/// given once layout runs.
@MainActor
struct WindowResizeTests {
    /// The real content tree (board + quota panel) populated with long-titled
    /// cards in every live column — the exact shape that wedged the window.
    private func windowWithBusyBoard() -> NSWindow {
        let shell = BoardShell(seeds: [])
        let root = shell.buildContentForTesting()
        shell.applySessions([
            BoardCard(
                sessionID: "q", title: "task-06-generations-per-link-longer-still",
                projectDir: "/Users/x/MyProjects/barbershop-idea-testing",
                agent: .claude, flow: .a, state: .idle),
            BoardCard(
                sessionID: "w", title: "another-extremely-long-working-task-title",
                projectDir: "/Users/x/MyProjects/agentic-coding-kanban",
                agent: .codex, flow: .b, state: .running),
            BoardCard(
                sessionID: "n", title: "a-blocked-task-with-a-very-verbose-name",
                projectDir: "/Users/x/MyProjects/sahaidachny",
                agent: .gemini, flow: .a, state: .waitingForInput),
        ])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.contentView = root
        return window
    }

    /// A shrink to 700pt — far below the cards' natural width — must hold after a
    /// layout pass. RED before the fix: card text at 750 compression resistance
    /// out-ranks the window and layout grows the frame straight back.
    @Test func shrunkWindowStaysShrunk() {
        let window = windowWithBusyBoard()
        window.layoutIfNeeded()

        window.setFrame(NSRect(x: 0, y: 0, width: 700, height: 500), display: true)
        window.layoutIfNeeded()

        #expect(window.frame.width == 700)
        #expect(window.frame.height == 500)
    }

    /// The launch-sized window must not be inflated by its own content either —
    /// this is what pushed the real board to 2053pt on an 1800pt screen.
    @Test func contentNeverGrowsTheWindow() {
        let window = windowWithBusyBoard()
        let before = window.frame

        window.layoutIfNeeded()

        #expect(window.frame == before)
    }
}
