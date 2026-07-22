import Testing
@testable import SichCore

// The paste path of `TerminalSurface`, tested window-free: each classified
// pasteboard payload must encode to the exact PTY bytes a real terminal sends —
// including the ⌃V image trigger that gives Claude Code image-paste parity.

@Suite("Paste payload → PTY byte encoding")
struct PasteEncoderTests {

    @Test("text wraps in bracketed-paste markers when the child enabled DEC 2004")
    func textBracketed() {
        #expect(PasteEncoder.bytes(for: .text("hi"), bracketed: true)
            == Array("\u{1B}[200~hi\u{1B}[201~".utf8))
    }

    @Test("text passes through raw when bracketed paste is off")
    func textPlain() {
        #expect(PasteEncoder.bytes(for: .text("hi"), bracketed: false) == [0x68, 0x69])
    }

    @Test("empty text sends nothing — no stray bracket markers")
    func emptyTextIsSilent() {
        #expect(PasteEncoder.bytes(for: .text(""), bracketed: true) == [])
        #expect(PasteEncoder.bytes(for: .filePaths([]), bracketed: true) == [])
    }

    @Test("an image-only clipboard encodes to the ⌃V trigger — the keystroke Claude Code answers by reading the OS clipboard itself")
    func imageIsCtrlVTrigger() {
        #expect(PasteEncoder.bytes(for: .imageOnClipboard, bracketed: false) == [0x16])
        // A keystroke, not a paste: bracketed mode must never wrap it.
        #expect(PasteEncoder.bytes(for: .imageOnClipboard, bracketed: true) == [0x16])
    }

    @Test("file paths paste shell-escaped and space-joined, as one bracketed paste")
    func filePathsEscapeAndJoin() {
        let bytes = PasteEncoder.bytes(
            for: .filePaths(["/tmp/My Shot (1).png", "/a/b.png"]), bracketed: true)
        #expect(bytes == Array(
            "\u{1B}[200~/tmp/My\\ Shot\\ \\(1\\).png /a/b.png\u{1B}[201~".utf8))
    }

    @Test("shell escaping quotes metacharacters and leaves plain path characters alone")
    func shellEscaping() {
        #expect(PasteEncoder.shellEscape("/ok/plain_file-1.png") == "/ok/plain_file-1.png")
        #expect(PasteEncoder.shellEscape("a b'c\"d$e") == "a\\ b\\'c\\\"d\\$e")
    }
}
