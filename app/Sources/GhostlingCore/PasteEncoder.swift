import Foundation

/// What one paste gesture carried. The AppKit layer (`TerminalSurface`) classifies
/// the pasteboard into one of these; ``PasteEncoder`` turns it into PTY bytes.
/// Window-free, like ``KeyInput``/``KeyEncoder``, so the paste path is testable
/// without a pasteboard.
public enum PastePayload: Equatable, Sendable {
    /// Plain text — the classic paste.
    case text(String)
    /// Files (Finder "Copy", or a drag onto the terminal): paste their
    /// shell-escaped paths, the way Terminal.app/iTerm2 do. An agent child
    /// (Claude Code) picks an image path out of its prompt by itself.
    case filePaths([String])
    /// The clipboard holds an image and no text. A PTY cannot transmit pixels;
    /// the convention (Claude Code's image paste) is that the child receives the
    /// ⌃V keystroke and reads the OS clipboard itself — so this encodes to
    /// exactly that trigger byte.
    case imageOnClipboard
}

/// Pure translation of a ``PastePayload`` into the bytes the child expects —
/// the testable seam behind `TerminalSurface`'s ⌘V / file-drop handling.
public enum PasteEncoder {
    /// ⌃V (0x16): the "read your clipboard" keystroke an agent TUI listens for.
    public static let imageTrigger: [UInt8] = [0x16]

    /// Encode one paste gesture. `bracketed` mirrors DEC mode 2004
    /// (``Terminal/bracketedPasteEnabled``): text-like payloads get wrapped so a
    /// TUI receives one paste, not replayed keystrokes.
    public static func bytes(for payload: PastePayload, bracketed: Bool) -> [UInt8] {
        switch payload {
        case .text(let text):
            return textBytes(text, bracketed: bracketed)
        case .filePaths(let paths):
            return textBytes(paths.map(shellEscape).joined(separator: " "), bracketed: bracketed)
        case .imageOnClipboard:
            return imageTrigger   // a keystroke, never bracketed
        }
    }

    private static func textBytes(_ text: String, bracketed: Bool) -> [UInt8] {
        guard !text.isEmpty else { return [] }
        let payload = bracketed ? "\u{1B}[200~\(text)\u{1B}[201~" : text
        return Array(payload.utf8)
    }

    /// Backslash-escape shell metacharacters in a path (Terminal.app's style), so
    /// `/tmp/My Shot (1).png` pastes as one word — both for a shell and for an
    /// agent prompt that splits on unescaped spaces.
    public static func shellEscape(_ path: String) -> String {
        let plain: Set<Character> = Set("/._-+~@%:,=")
        return String(path.flatMap { ch -> [Character] in
            ch.isLetter || ch.isNumber || plain.contains(ch) ? [ch] : ["\\", ch]
        })
    }
}
