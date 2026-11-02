import AppKit
import Foundation
import SichCore
import Testing

@testable import SichApp

/// The folder stage's inline completion, driven through the real field editor: typed
/// characters go in through `insertText`, ⇥/↑↓/↵ as dispatched key events — the way a
/// physical keyboard reaches the palette.
@MainActor
private func mount(_ palette: CreateCardPalette) -> (NSView, NSWindow) {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
    palette.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(palette)
    NSLayoutConstraint.activate([
        palette.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        palette.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        palette.topAnchor.constraint(equalTo: root.topAnchor),
        palette.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    let window = NSWindow(
        contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = root
    window.makeKeyAndOrderFront(nil)
    palette.focusStage()
    root.layoutSubtreeIfNeeded()
    return (root, window)
}

@MainActor
private func press(_ keyCode: UInt16, chars: String = "", in window: NSWindow) {
    let down = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: keyCode)!
    window.sendEvent(down)
}

private let kReturn: UInt16 = 36
private let kTab: UInt16 = 48
private let kDown: UInt16 = 125
private let kUp: UInt16 = 126
/// Arrow keys reach a field editor as function-key characters, not bare key codes.
private let downArrow = "\u{F701}"
private let upArrow = "\u{F700}"

/// Type into whichever field holds focus, through its editor, so the delegate's
/// text-change path runs exactly as it does for a keystroke.
@MainActor
private func type(_ text: String, in window: NSWindow) throws {
    let editor = try #require(window.firstResponder as? NSTextView, "a field editor must be focused")
    editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
}

/// Canned listings keyed by host + folder; answers synchronously like the local source.
@MainActor
private final class CannedFolders: FolderSuggestionSource {
    var listings: [String: [String]] = [:]
    /// Optional second level, keyed like `listings`, for a source that looks ahead.
    var lookahead: [String: [String: [String]]] = [:]
    private(set) var requests: [String] = []

    func subdirectories(
        of parent: String, on host: String?,
        completion: @escaping @MainActor (FolderCompletion.Tree?) -> Void
    ) {
        let key = "\(host ?? "local"):\(parent)"
        requests.append(key)
        completion(listings[key].map {
            FolderCompletion.Tree(children: $0, grandchildren: lookahead[key] ?? [:])
        })
    }
}

@MainActor
private func scratchTree() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sich-folders-\(UUID().uuidString)", isDirectory: true)
    for name in ["alpha", "alps", "beta", ".hidden"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Data().write(to: root.appendingPathComponent("notes.txt"))
    return root
}

@MainActor
@Test("local: typing lists the real subfolders, ⇥ fills the shared prefix, ↓↵ uses the pick")
func localCompletionFromDisk() throws {
    let tree = try scratchTree()
    defer { try? FileManager.default.removeItem(at: tree) }
    let palette = CreateCardPalette(recents: [])
    let (_, window) = mount(palette)
    var chosen: String?
    palette.confirmInteractive = { _, dir, _, _, _ in chosen = dir }

    press(kReturn, chars: "\r", in: window)                   // This Mac
    #expect(palette.stage == .project)
    try type(tree.path + "/", in: window)
    #expect(palette.folderSuggestions == ["alpha", "alps", "beta"].map { tree.path + "/" + $0 },
            "files and hidden folders stay out of the list")

    try type("al", in: window)
    #expect(palette.folderSuggestions == [tree.path + "/alpha", tree.path + "/alps"])
    press(kTab, chars: "\t", in: window)
    #expect(palette.dirField.stringValue == tree.path + "/alp", "⇥ extends to what both share")
    #expect(palette.folderSuggestions == [tree.path + "/alpha", tree.path + "/alps"], "…and keeps listing")

    press(kDown, chars: downArrow, in: window)                // highlight alpha
    press(kReturn, chars: "\r", in: window)
    #expect(palette.stage == .harness, "a highlighted folder is taken by ↵")
    press(kReturn, chars: "\r", in: window)                   // Claude Code
    press(kReturn, chars: "\r", in: window)                   // default account
    palette.nameField.stringValue = "work"
    press(kReturn, chars: "\r", in: window)
    #expect(chosen == tree.path + "/alpha")
}

@MainActor
@Test("local: ⇥ on a single match steps into it, and a typed folder that is missing is refused inline")
func localTabDrillsAndMissingFolderIsRefused() throws {
    let tree = try scratchTree()
    defer { try? FileManager.default.removeItem(at: tree) }
    let palette = CreateCardPalette(recents: [])
    let (_, window) = mount(palette)

    press(kReturn, chars: "\r", in: window)
    try type(tree.path + "/be", in: window)
    #expect(palette.folderSuggestions == [tree.path + "/beta"])
    press(kTab, chars: "\t", in: window)
    #expect(palette.dirField.stringValue == tree.path + "/beta/")
    #expect(palette.folderSuggestions.isEmpty, "beta has no subfolders")

    try type("nope", in: window)
    press(kReturn, chars: "\r", in: window)
    #expect(palette.stage == .project, "the stage holds")
    #expect(!palette.errorLabel.isHidden)
    #expect(palette.errorLabel.stringValue.hasPrefix("No folder at"))
}

@MainActor
@Test("local: an empty field keeps ↵ on the highlighted recent, and ↑ wraps to the last row")
func emptyFieldStillPicksRecents() throws {
    let tree = try scratchTree()
    defer { try? FileManager.default.removeItem(at: tree) }
    let a = tree.appendingPathComponent("alpha").path
    let b = tree.appendingPathComponent("beta").path
    let palette = CreateCardPalette(recents: [
        PaletteProject(path: a), PaletteProject(path: b),
    ])
    let (_, window) = mount(palette)
    var chosen: String?
    palette.confirmInteractive = { _, dir, _, _, _ in chosen = dir }

    press(kReturn, chars: "\r", in: window)
    #expect(palette.navRows.map(\.titleText) == ["alpha", "beta"])
    press(kUp, chars: upArrow, in: window)                    // ↑ from the first row
    press(kReturn, chars: "\r", in: window)
    press(kReturn, chars: "\r", in: window)
    press(kReturn, chars: "\r", in: window)
    press(kReturn, chars: "\r", in: window)
    #expect(chosen == b, "↑ wrapped to the last recent")
}

@MainActor
@Test("local: a bare name is a folder under home — no ~/ needed to list, step in, or commit")
func bareNameResolvesUnderHome() throws {
    let tree = try scratchTree()
    defer { try? FileManager.default.removeItem(at: tree) }
    let palette = CreateCardPalette(recents: [])
    palette.home = tree.path
    let (_, window) = mount(palette)
    var chosen: String?
    palette.confirmInteractive = { _, dir, _, _, _ in chosen = dir }

    press(kReturn, chars: "\r", in: window)                   // This Mac
    try type("AL", in: window)
    #expect(palette.folderSuggestions == ["alpha", "alps"], "case does not matter")
    press(kTab, chars: "\t", in: window)
    #expect(palette.navRows.first?.isSelected == true,
            "⇥ cannot extend what was typed without changing its case, so it highlights")
    press(kTab, chars: "\t", in: window)
    #expect(palette.dirField.stringValue == "alpha/", "the next ⇥ steps into the highlighted folder")
    #expect(palette.folderHeading.stringValue.hasPrefix("NO FOLDERS IN ~/alpha/"),
            "a bare parent is listed under home, not refused: \(palette.folderHeading.stringValue)")

    press(kReturn, chars: "\r", in: window)
    #expect(palette.stage == .harness, "a bare path commits under home")
    press(kReturn, chars: "\r", in: window)                   // Claude Code
    press(kReturn, chars: "\r", in: window)                   // default account
    palette.nameField.stringValue = "work"
    press(kReturn, chars: "\r", in: window)
    #expect(chosen == tree.path + "/alpha", "absolute, with no trailing slash")
}

@MainActor
@Test("local: a bare name is also looked up in the folders your recent projects live in")
func bareNameSearchesRecentProjectRoots() throws {
    let tree = try scratchTree()
    defer { try? FileManager.default.removeItem(at: tree) }
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("sich-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("better"),
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let palette = CreateCardPalette(recents: [PaletteProject(path: tree.appendingPathComponent("alpha").path)])
    palette.home = home.path
    let (_, window) = mount(palette)
    var chosen: String?
    palette.confirmInteractive = { _, dir, _, _, _ in chosen = dir }

    press(kReturn, chars: "\r", in: window)
    try type("bet", in: window)
    #expect(palette.folderSuggestions == ["better", tree.path + "/beta"],
            "home first, then the sibling of a recent project")
    #expect(palette.navRows.map(\.titleText) == ["better", "beta"])
    #expect(palette.folderHeading.stringValue.contains("YOUR PROJECT FOLDERS"))

    try type("a", in: window)                                  // "beta"
    #expect(palette.folderSuggestions == [tree.path + "/beta"])
    press(kDown, chars: downArrow, in: window)
    press(kReturn, chars: "\r", in: window)
    #expect(palette.stage == .harness)
    press(kReturn, chars: "\r", in: window)
    press(kReturn, chars: "\r", in: window)
    palette.nameField.stringValue = "work"
    press(kReturn, chars: "\r", in: window)
    #expect(chosen == tree.path + "/beta")
}

@MainActor
@Test("remote: the host's own listing completes the field, one request per folder")
func remoteCompletionListsOncePerFolder() throws {
    let source = CannedFolders()
    source.listings["me@box:/srv/"] = ["app", "archive", "www"]
    let palette = CreateCardPalette(recents: [])
    palette.folderSource = source
    let (_, window) = mount(palette)
    var committed: (host: String, dir: String)?
    palette.confirmRemote = { _, host, dir, _ in committed = (host, dir); return nil }

    palette.hostField.stringValue = "me@box"
    press(kReturn, chars: "\r", in: window)
    #expect(palette.stage == .project)
    try type("/srv/a", in: window)
    #expect(palette.folderSuggestions == ["/srv/app", "/srv/archive"])
    try type("p", in: window)
    #expect(palette.folderSuggestions == ["/srv/app"])
    #expect(source.requests == ["me@box:/srv/"], "typing inside a folder filters the cached listing")

    press(kTab, chars: "\t", in: window)
    #expect(palette.dirField.stringValue == "/srv/app/")
    #expect(source.requests == ["me@box:/srv/", "me@box:/srv/app/"], "stepping in lists the new folder")
    #expect(palette.folderSuggestions.isEmpty, "an unlistable folder offers nothing…")

    press(kReturn, chars: "\r", in: window)
    #expect(palette.stage == .task, "…but never blocks: ↵ takes the path as typed")
    palette.nameField.stringValue = "deploy"
    press(kReturn, chars: "\r", in: window)
    #expect(committed?.host == "me@box")
    #expect(committed?.dir == "/srv/app/")
}

@MainActor
@Test("remote: a listing that lands later repaints only if the field still looks at that folder")
func lateListingRepaintsTheRightFolder() throws {
    final class Deferred: FolderSuggestionSource {
        var pending: [(String, @MainActor (FolderCompletion.Tree?) -> Void)] = []
        func subdirectories(
            of parent: String, on host: String?,
            completion: @escaping @MainActor (FolderCompletion.Tree?) -> Void
        ) { pending.append((parent, completion)) }
    }
    let source = Deferred()
    let palette = CreateCardPalette(recents: [])
    palette.folderSource = source
    let (_, window) = mount(palette)

    palette.hostField.stringValue = "box"
    press(kReturn, chars: "\r", in: window)
    try type("/srv/", in: window)
    #expect(palette.folderSuggestions.isEmpty, "still listing")
    try type("w", in: window)
    #expect(source.pending.count == 1, "the same folder is not asked twice while in flight")
    source.pending[0].1(FolderCompletion.Tree(children: ["app", "www"]))
    #expect(palette.folderSuggestions == ["/srv/www"], "the late answer is filtered by what was typed since")
}

@MainActor
@Test("browsing: every subfolder is a row, ↑ wraps to the last one and scrolls it into view, → steps in")
func bigFolderIsBrowsableWithoutKnowingNames() throws {
    let source = CannedFolders()
    let names = (1...30).map { String(format: "folder-%02d", $0) }
    source.listings["box:/srv/"] = names
    source.listings["box:/srv/folder-30/"] = ["inner"]
    let palette = CreateCardPalette(recents: [])
    palette.folderSource = source
    let (root, window) = mount(palette)

    palette.hostField.stringValue = "box"
    press(kReturn, chars: "\r", in: window)
    try type("/srv/", in: window)
    #expect(palette.folderSuggestions.count == 30, "nothing is cut off")
    #expect(palette.navRows.count == 30)
    root.layoutSubtreeIfNeeded()
    let pane = palette.folderScrollForTesting
    #expect(pane.frame.height <= CreateCardPalette.folderListMaxHeight)
    #expect(pane.documentView!.frame.height > pane.frame.height, "the list scrolls")

    press(kUp, chars: upArrow, in: window)                    // wraps to folder-30
    root.layoutSubtreeIfNeeded()
    let last = try #require(palette.navRows.last)
    #expect(last.isSelected)
    let lastInDoc = last.convert(last.bounds, to: pane.documentView)
    #expect(pane.documentVisibleRect.contains(lastInDoc), "the highlighted row was scrolled into view")

    press(124, chars: "\u{F703}", in: window)                 // → steps in
    #expect(palette.dirField.stringValue == "/srv/folder-30/")
    #expect(palette.folderSuggestions == ["/srv/folder-30/inner"])
}

@MainActor
@Test("remote: a two-level listing makes the next step-in instant, with no second request")
func lookaheadAnswersTheNextStepIn() throws {
    let source = CannedFolders()
    source.listings["box:/srv/"] = ["app", "www"]
    source.lookahead["box:/srv/"] = ["app": ["src", "tests"], "www": []]
    let palette = CreateCardPalette(recents: [])
    palette.folderSource = source
    let (_, window) = mount(palette)

    palette.hostField.stringValue = "box"
    press(kReturn, chars: "\r", in: window)
    try type("/srv/ap", in: window)
    press(kTab, chars: "\t", in: window)
    #expect(palette.dirField.stringValue == "/srv/app/")
    #expect(palette.folderSuggestions == ["/srv/app/src", "/srv/app/tests"], "served from the look-ahead")
    #expect(source.requests == ["box:/srv/"], "no handshake for the step-in")
}

@MainActor
@Test("a huge folder renders a bounded number of rows and says how many more there are")
func hugeFolderIsCapped() throws {
    let source = CannedFolders()
    source.listings["box:/big/"] = (0..<500).map { String(format: "d%03d", $0) }
    let palette = CreateCardPalette(recents: [])
    palette.folderSource = source
    let (_, window) = mount(palette)

    palette.hostField.stringValue = "box"
    press(kReturn, chars: "\r", in: window)
    try type("/big/", in: window)
    #expect(palette.navRows.count == CreateCardPalette.maxFolderRows)
    #expect(palette.folderSuggestions.count == CreateCardPalette.maxFolderRows)
    try type("d49", in: window)
    #expect(palette.folderSuggestions.count == 10, "typing narrows past the cap")
}
