import AppKit
import Carbon.HIToolbox

/// Latin identity of a hardware key, independent of the active input source.
///
/// `charactersIgnoringModifiers` follows the current layout, so on Ukrainian the
/// V key is "м". Control and Command chords matched that string and died: ⌃V
/// encoded to nothing, ⌘V never pasted. Shortcuts follow the ASCII-capable
/// layout (the Latin layout last used for typing — US, ABC, German, …) and,
/// if that lookup fails, the ANSI virtual-key positions those layouts share.
enum ASCIILayoutKey {
    /// Character a Command/Control shortcut should match. An ASCII letter or
    /// mark from the event wins (English, and any layout that already produced
    /// one). Otherwise the hardware key is resolved to its Latin character.
    nonisolated static func shortcutCharacter(for event: NSEvent) -> Character? {
        if let typed = asciiCharacter(event.charactersIgnoringModifiers?.first) {
            return typed
        }
        return character(for: event.keyCode)
    }

    /// Latin character of a virtual key code. Nil for keys with no Latin form
    /// (arrows, Escape, function keys).
    nonisolated static func character(for keyCode: UInt16) -> Character? {
        if let translated = asciiCharacter(translate(keyCode)) { return translated }
        return ansiFallback[keyCode]
    }

    /// Letters come back lowercase so ⌘V and ⌘⇧V share one match. Non-letters
    /// ("[") pass through. Non-ASCII (Cyrillic "м") is not a shortcut character.
    private nonisolated static func asciiCharacter(_ raw: Character?) -> Character? {
        guard let raw else { return nil }
        if let lower = raw.lowercased().first, lower.isASCII, lower.isLetter {
            return lower
        }
        if raw.isASCII, !raw.isLetter { return raw }
        return nil
    }

    private nonisolated static func translate(_ keyCode: UInt16) -> Character? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let base = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(base).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeys, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).first
    }

    /// US-ANSI positions. Right for Ukrainian-on-a-US-keyboard (the reported
    /// case) when the layout database can't be read; a Latin layout that moves
    /// keys (Dvorak) is handled by `translate` above and never reaches here.
    private nonisolated static let ansiFallback: [UInt16: Character] = [
        UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_C): "c",
        UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_E): "e", UInt16(kVK_ANSI_F): "f",
        UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_H): "h", UInt16(kVK_ANSI_I): "i",
        UInt16(kVK_ANSI_J): "j", UInt16(kVK_ANSI_K): "k", UInt16(kVK_ANSI_L): "l",
        UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_O): "o",
        UInt16(kVK_ANSI_P): "p", UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r",
        UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_T): "t", UInt16(kVK_ANSI_U): "u",
        UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_X): "x",
        UInt16(kVK_ANSI_Y): "y", UInt16(kVK_ANSI_Z): "z",
        UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_Equal): "=", UInt16(kVK_ANSI_Minus): "-",
        UInt16(kVK_ANSI_0): "0",
    ]
}

/// AppKit matches menu key equivalents against `charactersIgnoringModifiers`.
/// On Ukrainian that is "м" for the V key, so the Edit menu's Paste item (⌘V)
/// never fires and every text field refuses the paste. After the normal search
/// misses, retry against the key's Latin character.
final class LayoutAwareMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard let item = Self.latinItem(matching: event, in: self),
              let menu = item.menu,
              let index = menu.items.firstIndex(of: item)
        else { return false }
        // AppKit sends the action down the responder chain (nil target → the
        // focused field's paste:). Staying on this call avoids a main-actor hop.
        menu.performActionForItem(at: index)
        return true
    }

    /// Item whose key equivalent is the event's Latin character and whose
    /// modifiers agree. Searches submenus, because the main menu's items are
    /// the menus themselves.
    private static func latinItem(matching event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        guard let latin = ASCIILayoutKey.shortcutCharacter(for: event) else { return nil }
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // The ordinary search already had a chance at an ASCII chord.
        guard typed != String(latin) else { return nil }
        return item(latin: latin, flags: event.modifierFlags, in: menu)
    }

    private static func item(latin: Character, flags: NSEvent.ModifierFlags,
                             in menu: NSMenu) -> NSMenuItem? {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let want = flags.intersection(relevant)
        for entry in menu.items {
            if let submenu = entry.submenu,
               let found = item(latin: latin, flags: flags, in: submenu) {
                return found
            }
            guard !entry.keyEquivalent.isEmpty,
                  entry.keyEquivalent.lowercased() == String(latin),
                  entry.keyEquivalentModifierMask.intersection(relevant) == want
            else { continue }
            return entry
        }
        return nil
    }
}
