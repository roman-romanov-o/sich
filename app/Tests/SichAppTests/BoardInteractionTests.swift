import AppKit
import SichCore
import Testing

@testable import SichApp

/// Real-event interaction tests for the board's two mutating gestures — a card
/// dragged to a new column (manual state change) and the add-task icon
/// affordance. Per the Interaction-AC Binding Rule, these drive the actual AppKit
/// seams (the drop-delivery `performDragOperation` with a real pasteboard payload;
/// the button's own action dispatch), NOT the `onMove`/`onCreate` closures
/// directly — a handler call would leave the interaction path unverified, which is
/// exactly the false-pass that shipped a broken gesture green before.
@MainActor
@Suite("Board interaction wiring — drag-to-column + add-task")
struct BoardInteractionTests {

    private func board() -> BoardView {
        let view = BoardView()
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        return view
    }

    private func firstButton(in view: NSView, identifier: String) -> NSButton? {
        if let b = view as? NSButton, b.identifier?.rawValue == identifier { return b }
        for sub in view.subviews {
            if let found = firstButton(in: sub, identifier: identifier) { return found }
        }
        return nil
    }

    private func cell(in view: NSView, column: BoardColumn) -> BoardCell? {
        if let c = view as? BoardCell, c.column == column { return c }
        for sub in view.subviews {
            if let found = cell(in: sub, column: column) { return found }
        }
        return nil
    }

    /// The drop half of a column move, exercised through `performDragOperation` —
    /// the exact NSDraggingDestination entry point AppKit calls when a card is
    /// dropped — carrying the SAME pasteboard payload `SessionCard`'s drag source
    /// writes (`card.id.uuidString` under `BoardCell.cardType`). RED if the
    /// decode-and-fire wiring (`performDragOperation → onDrop → onMove`) breaks or
    /// the pasteboard-type contract drifts.
    @Test("dropping a card on another column fires onMove to that column")
    func dropOnColumnFiresOnMove() throws {
        let view = board()
        var moved: (id: UUID, column: BoardColumn)?
        view.onMove = { id, col in moved = (id, col) }

        let card = BoardCard(sessionID: "s", projectDir: "~/x", agent: .claude, state: .idle)
        view.render(cards: [card])   // lands in the idle column

        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString(card.id.uuidString, forType: BoardCell.cardType)

        let target = try #require(cell(in: view, column: .done), "the done column must exist")
        #expect(target.performDragOperation(DropInfo(pasteboard: pb)),
            "a valid card payload dropped on a column must be accepted")
        #expect(moved?.id == card.id, "onMove must carry the dragged card's id")
        #expect(moved?.column == .done, "dropped on done → onMove(.done)")
    }

    /// Non-vacuity + input validation: an unparseable payload is rejected and no
    /// move fires — so the green above is the decode actually succeeding, not the
    /// closure firing unconditionally.
    @Test("a drop with a non-UUID payload is rejected and fires no move")
    func dropWithGarbagePayloadIsRejected() throws {
        let view = board()
        var fired = false
        view.onMove = { _, _ in fired = true }
        view.render(cards: [])

        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("not-a-uuid", forType: BoardCell.cardType)

        let target = try #require(cell(in: view, column: .done))
        #expect(target.performDragOperation(DropInfo(pasteboard: pb)) == false)
        #expect(fired == false, "a malformed payload must not move any card")
    }

    /// The add-task affordance, fired through the icon button's own action
    /// dispatch (`performClick` → target/action → `createTapped`), NOT a direct
    /// `onCreate()` call — so an unwired button fails here. A stock `NSButton`'s
    /// mouse tracking needs the window's live event stream, so `performClick` (the
    /// button's click path) is the deterministic headless seam.
    /// ponytail: performClick over a synthetic mouseDown — an NSButton mouseDown
    /// blocks on a tracking loop awaiting mouseUp from the window; upgrade to a full
    /// NSEvent round-trip only if the target/action wiring ever needs proving too.
    @Test("clicking the add-task icon fires onCreate")
    func addTaskButtonFiresOnCreate() throws {
        let view = board()
        var created = false
        view.onCreate = { created = true }
        view.render(cards: [])

        let button = try #require(firstButton(in: view, identifier: "add-task"),
            "the add-task icon must be in the QUEUE header")
        #expect(button.title.isEmpty, "the compact header action must not render a text label")
        #expect(button.image != nil, "the add-task action needs a visible icon")
        #expect(button.toolTip == "Add task", "the icon must explain itself on hover")
        button.performClick(nil)
        #expect(created, "the add-task icon must fire onCreate")
    }
}

/// Minimal `NSDraggingInfo` for driving `performDragOperation` in a test: only
/// `draggingPasteboard` carries meaning (the real payload); the rest are inert
/// stubs never read on the drop path. Test-only.
@MainActor
private final class DropInfo: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var numberOfValidItemsForDrop: Int = 0
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
