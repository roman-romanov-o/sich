import AppKit
import SichCore
import Testing

@testable import SichApp

/// Image/file paste parity with a stock terminal running Claude Code. Two gaps
/// motivated these: ⌘V silently no-opped when the clipboard held an image (the
/// screenshot-to-clipboard flow), and a file dragged onto the terminal did
/// nothing. Per the Interaction-AC Binding Rule, the key paths are driven by
/// REAL dispatched `NSEvent`s, and delivery is asserted at the PTY write
/// boundary (`PTYSession.onInput`) — not by calling `paste()` directly.
@MainActor
@Suite("Terminal image/file paste (⌘V routing, ⌃V passthrough, file drop)")
struct TerminalPasteTests {

    /// A live surface over a real `/bin/cat` child, with an injected unique-name
    /// pasteboard and an input spy. Caller must `terminate()` the session.
    private func makeSurface() throws -> (TerminalSurface, PTYSession, NSPasteboard) {
        let session = try PTYSession(command: ["/bin/cat"])
        try session.start()
        let surface = TerminalSurface(session: session)
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        surface.pasteboard = pb
        return (surface, session, pb)
    }

    private func cmdV(windowNumber: Int = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ))
    }

    // MARK: - ⌘V routing

    @Test("⌘V with an image-only clipboard sends the ⌃V trigger to the child (real key-event path)")
    func cmdVWithImageOnlyClipboardSendsTrigger() throws {
        let (surface, session, pb) = try makeSurface()
        defer { session.terminate() }
        pb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)   // screenshot-style: image, no text

        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        #expect(surface.performKeyEquivalent(with: try cmdV()) == true,
            "the surface must claim ⌘V")
        #expect(sent == [0x16],
            "an image-only paste must deliver ⌃V so the child reads the clipboard itself")
    }

    @Test("⌘V with plain text still pastes the text — the image path must not regress it")
    func cmdVWithTextStillPastesText() throws {
        let (surface, session, pb) = try makeSurface()
        defer { session.terminate() }
        pb.setString("hello", forType: .string)

        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        #expect(surface.performKeyEquivalent(with: try cmdV()) == true)
        #expect(sent == Array("hello".utf8))   // cat never enables DEC 2004 → raw
    }

    @Test("⌘V with a copied file pastes its shell-escaped path, beating Finder's name-only string")
    func cmdVWithCopiedFilePastesPath() throws {
        let (surface, session, pb) = try makeSurface()
        defer { session.terminate() }
        // Finder's "Copy" shape: a file URL AND the bare display name as string.
        pb.writeObjects([NSURL(fileURLWithPath: "/tmp/My Shot.png")])
        pb.setString("My Shot.png", forType: .string)

        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        #expect(surface.performKeyEquivalent(with: try cmdV()) == true)
        #expect(sent == Array("/tmp/My\\ Shot.png".utf8),
            "the full escaped path is the useful paste, not the display name")
    }

    @Test("⌘V with an empty pasteboard sends nothing")
    func cmdVEmptyIsSilent() throws {
        let (surface, session, _) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }
        _ = surface.performKeyEquivalent(with: try cmdV())
        #expect(sent.isEmpty)
    }

    // MARK: - ⌃V passthrough (the vanilla Claude Code chord)

    @Test("plain ⌃V flows to the child as 0x16 — Claude Code's native image-paste chord (real key-event path)")
    func ctrlVKeystrokeReachesChild() throws {
        let (surface, session, _) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        let ctrlV = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "\u{16}", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ))
        surface.keyDown(with: ctrlV)

        #expect(sent == [0x16],
            "⌃V must reach the PTY untouched so the child's own image paste works")
    }

    // MARK: - File drop

    @Test("dropping a file onto the terminal pastes its escaped path plus a trailing space")
    func fileDropPastesPath() throws {
        let (surface, session, _) = try makeSurface()
        defer { session.terminate() }
        let dropPB = NSPasteboard.withUniqueName()
        dropPB.clearContents()
        dropPB.writeObjects([NSURL(fileURLWithPath: "/tmp/shot 1.png")])

        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        let info = DropInfo(pasteboard: dropPB)
        #expect(surface.draggingEntered(info) == .copy)
        #expect(surface.performDragOperation(info) == true)
        #expect(sent == Array("/tmp/shot\\ 1.png ".utf8))
    }

    @Test("a drag with no file URLs is refused")
    func nonFileDragIsRefused() throws {
        let (surface, session, _) = try makeSurface()
        defer { session.terminate() }
        let dropPB = NSPasteboard.withUniqueName()
        dropPB.clearContents()
        dropPB.setString("just text", forType: .string)

        let info = DropInfo(pasteboard: dropPB)
        #expect(surface.draggingEntered(info) == [])
        #expect(surface.performDragOperation(info) == false)
    }
}

/// Minimal `NSDraggingInfo` for driving the surface's drop path in a test: only
/// `draggingPasteboard` carries meaning; the rest are inert stubs. Test-only.
/// (Mirrors `BoardInteractionTests`' private mock — kept file-local like that one.)
@MainActor
private final class DropInfo: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSourceOperationMask: NSDragOperation { .copy }
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
