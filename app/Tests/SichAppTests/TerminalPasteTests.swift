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

    // MARK: - Large paste lands whole

    /// The "my paste came out cropped" defect. The pty input queue holds ~1KB and
    /// the master fd is non-blocking, so a single write drops most of a big paste.
    /// Real ⌘V, real run loop: the surface's writability source must feed the
    /// remainder as the child drains, and every byte must arrive, in order.
    @Test("⌘V of a clipboard far larger than the tty input queue reaches the child whole")
    func cmdVLargeTextArrivesWhole() throws {
        let out = NSTemporaryDirectory() + "sich-paste-out-" + UUID().uuidString
        let done = NSTemporaryDirectory() + "sich-paste-done-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(atPath: out)
            try? FileManager.default.removeItem(atPath: done)
        }
        let text = String(repeating: "0123456789abcdef\n", count: 3_000)   // 51KB
        // A raw-mode child (what every TUI is) that swallows exactly the paste,
        // then leaves a sentinel it can only reach once all bytes arrived.
        let session = try PTYSession(command: ["/bin/sh", "-c",
            "stty raw -echo; head -c \(text.utf8.count) > '\(out)'; : > '\(done)'"])
        try session.start()
        defer { session.terminate() }
        let surface = TerminalSurface(session: session)
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString(text, forType: .string)
        surface.pasteboard = pb
        surface.startReading()
        defer { surface.stopReading() }
        spinMainRunLoop(until: 3.0) {
            var t = termios()
            return tcgetattr(session.masterFD, &t) == 0 && t.c_lflag & UInt(ICANON) == 0
        }

        #expect(surface.performKeyEquivalent(with: try cmdV()) == true)
        spinMainRunLoop(until: 5.0) { FileManager.default.fileExists(atPath: done) }

        let received = FileManager.default.contents(atPath: out) ?? Data()
        #expect(received.count == text.utf8.count,
            "child received \(received.count) of \(text.utf8.count) pasted bytes")
        #expect(received == Data(text.utf8), "pasted bytes arrived out of order or corrupted")
        #expect(session.pendingInputCount == 0, "nothing may be left queued once the child took it all")
    }

    private func spinMainRunLoop(until timeout: TimeInterval, done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
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

    /// Ukrainian (and any non-Latin layout) reports the V key as "м", not "v".
    /// Matching that character made ⌘V a no-op and ⌃V encode to zero bytes.
    @Test("⌘V still pastes when the V key's layout character is Cyrillic")
    func cmdVPastesWhenLayoutCharacterIsCyrillic() throws {
        let (surface, session, pb) = try makeSurface()
        defer { session.terminate() }
        pb.setString("hello", forType: .string)
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        #expect(surface.performKeyEquivalent(with: try layoutKey(
            modifiers: .command, keyCode: 9, glyph: "м")) == true)
        #expect(sent == Array("hello".utf8))
    }

    @Test("⌃V and ⌃C follow the physical key when the layout character is Cyrillic")
    func controlChordsFollowPhysicalKey() throws {
        let (surface, session, _) = try makeSurface()
        defer { session.terminate() }
        // V is "м", C is "с" on the Apple Ukrainian layout.
        let cases: [(UInt16, String, [UInt8])] = [
            (9, "м", [0x16]),
            (8, "с", [0x03]),
        ]
        for (keyCode, glyph, expected) in cases {
            var sent: [UInt8] = []
            session.onInput = { sent += $0 }
            surface.keyDown(with: try layoutKey(
                modifiers: .control, keyCode: keyCode, glyph: glyph))
            #expect(sent == expected, "keyCode \(keyCode) (\(glyph))")
        }
    }

    @Test("a Cyrillic letter without Control is typed as itself")
    func cyrillicLetterIsNotRemapped() throws {
        let (surface, session, _) = try makeSurface()
        defer { session.terminate() }
        var sent: [UInt8] = []
        session.onInput = { sent += $0 }

        surface.keyDown(with: try layoutKey(modifiers: [], keyCode: 9, glyph: "м"))

        #expect(sent == Array("м".utf8))
    }

    /// What AppKit delivers for a key when a non-Latin input source is active:
    /// the layout glyph in both character fields, the hardware key code unchanged.
    private func layoutKey(modifiers: NSEvent.ModifierFlags, keyCode: UInt16,
                           glyph: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: glyph, charactersIgnoringModifiers: glyph,
            isARepeat: false, keyCode: keyCode
        ))
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
