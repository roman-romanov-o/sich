import AppKit

/// The standard Edit menu.
///
/// This is not decoration. AppKit routes ⌘X/⌘C/⌘V/⌘A to the focused field editor ONLY
/// when a main-menu item carries that key equivalent — an `NSTextField` does not handle
/// the chord itself. So an app that builds its menu by hand and skips Edit (which is how
/// this went missing here) silently refuses to paste in every text field it owns: the
/// create palette's task name, host and remote folder fields included.
///
/// Every item targets nil so it resolves against the first responder rather than any one
/// view. The terminal is deliberately unaffected: a window's view hierarchy is offered a
/// key equivalent BEFORE the main menu, so `TerminalSurface.performKeyEquivalent` still
/// claims ⌘V first and keeps its bracketed-paste/file-path handling.
enum EditMenu {
    static func item() -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu()
        return item
    }

    private static func menu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // Undo/redo are responder actions with no exposed Swift selector.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")),
                                keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        return menu
    }
}
