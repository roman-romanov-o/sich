import Foundation

/// A logical key press, decoupled from AppKit so it can be unit-tested without a
/// window. `TerminalSurface` translates `NSEvent`s into these and then asks
/// ``KeyEncoder`` for the bytes to write to the PTY.
public enum KeyInput: Sendable, Equatable {
    /// One or more printable Unicode characters (e.g. typing "a" or pasting text).
    case text(String)
    case enter
    case tab
    case backspace
    case escape
    case up
    case down
    case right
    case left
    /// A Control-modified letter, e.g. `.control("c")` → ⌃C (0x03).
    case control(Character)
}

/// Pure, window-free translation of a ``KeyInput`` into the raw bytes a PTY child
/// expects. This is the testable seam behind `TerminalSurface`'s key handling —
/// the same mapping a real terminal performs, with no AppKit dependency.
public enum KeyEncoder {
    /// Encode one logical key press into PTY bytes.
    public static func bytes(for input: KeyInput) -> [UInt8] {
        switch input {
        case .text(let s): return Array(s.utf8)
        case .enter: return [0x0D]                 // CR
        case .tab: return [0x09]
        case .backspace: return [0x7F]             // DEL, what xterm sends for ⌫
        case .escape: return [0x1B]
        case .up: return csi("A")
        case .down: return csi("B")
        case .right: return csi("C")
        case .left: return csi("D")
        case .control(let c): return controlBytes(for: c)
        }
    }

    /// `ESC [` followed by the given final byte (cursor / arrow sequences).
    private static func csi(_ final: String) -> [UInt8] {
        [0x1B, 0x5B] + Array(final.utf8)
    }

    /// Map a letter to its Control code: ⌃A..⌃Z → 0x01..0x1A, e.g. ⌃C → 0x03.
    private static func controlBytes(for c: Character) -> [UInt8] {
        guard let ascii = c.lowercased().first?.asciiValue,
              ascii >= 0x61, ascii <= 0x7A else {
            return []
        }
        return [ascii - 0x60]
    }
}
