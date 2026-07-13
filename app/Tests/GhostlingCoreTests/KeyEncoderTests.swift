import Testing
@testable import GhostlingCore

// The keystroke path of `TerminalSurface`, tested window-free: a logical key
// press must encode to the exact PTY bytes a real terminal sends. This is the
// machine-assertable half of US-001 AC#1 (interactive input).

@Suite("Key event → PTY byte encoding")
struct KeyEncoderTests {

    @Test("Enter encodes to carriage return")
    func enterIsCR() {
        #expect(KeyEncoder.bytes(for: .enter) == [0x0D])
    }

    @Test("printable text encodes to its UTF-8 bytes")
    func textIsUTF8() {
        #expect(KeyEncoder.bytes(for: .text("hi")) == [0x68, 0x69])
        #expect(KeyEncoder.bytes(for: .text("é")) == Array("é".utf8))
    }

    @Test("Control-C encodes to 0x03 (ETX)")
    func ctrlCIsETX() {
        #expect(KeyEncoder.bytes(for: .control("c")) == [0x03])
        #expect(KeyEncoder.bytes(for: .control("C")) == [0x03])
    }

    @Test("Control-A..Control-Z map to 0x01..0x1A")
    func ctrlRange() {
        #expect(KeyEncoder.bytes(for: .control("a")) == [0x01])
        #expect(KeyEncoder.bytes(for: .control("z")) == [0x1A])
    }

    @Test("arrow keys encode to CSI cursor sequences", arguments: [
        (KeyInput.up, [UInt8]([0x1B, 0x5B, 0x41])),
        (KeyInput.down, [0x1B, 0x5B, 0x42]),
        (KeyInput.right, [0x1B, 0x5B, 0x43]),
        (KeyInput.left, [0x1B, 0x5B, 0x44]),
    ])
    func arrowsAreCSI(_ key: KeyInput, _ expected: [UInt8]) {
        #expect(KeyEncoder.bytes(for: key) == expected)
    }

    @Test("modified arrows / deletes encode to readline editing sequences", arguments: [
        (KeyInput.wordLeft, [UInt8]([0x1B, 0x62])),   // ESC b
        (KeyInput.wordRight, [0x1B, 0x66]),           // ESC f
        (KeyInput.lineStart, [0x01]),                 // ⌃A
        (KeyInput.lineEnd, [0x05]),                   // ⌃E
        (KeyInput.deleteWord, [0x1B, 0x7F]),          // ESC DEL
        (KeyInput.deleteLine, [0x15]),                // ⌃U
    ])
    func editingKeys(_ key: KeyInput, _ expected: [UInt8]) {
        #expect(KeyEncoder.bytes(for: key) == expected)
    }

    @Test("control / whitespace keys encode to their single bytes")
    func singleByteKeys() {
        #expect(KeyEncoder.bytes(for: .tab) == [0x09])
        #expect(KeyEncoder.bytes(for: .backspace) == [0x7F])
        #expect(KeyEncoder.bytes(for: .escape) == [0x1B])
    }
}
