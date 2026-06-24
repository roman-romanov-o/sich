import GhosttyVt

/// Thrown when a libghostty-vt C call returns a non-success result.
public struct TerminalError: Error, CustomStringConvertible {
    public let op: String
    public let code: Int32
    public var description: String { "libghostty-vt \(op) failed (code \(code))" }
}

/// A safe Swift wrapper over a libghostty-vt terminal emulator instance.
///
/// Owns the underlying `GhosttyTerminal` handle and frees it on `deinit`. Bytes
/// produced by a child process are fed in with ``write(_:)``; the rendered screen
/// is read back with ``plainText()`` — no screen-scraping, the same in-process
/// path proven by the Phase 00 spike.
public final class Terminal {
    private let handle: GhosttyTerminal

    public init(cols: UInt16 = 80, rows: UInt16 = 24, maxScrollback: Int = 1000) throws {
        var handle: GhosttyTerminal?
        let opts = GhosttyTerminalOptions(cols: cols, rows: rows, max_scrollback: maxScrollback)
        let r = ghostty_terminal_new(nil, &handle, opts)
        guard r == GHOSTTY_SUCCESS, let handle else {
            throw TerminalError(op: "ghostty_terminal_new", code: r.rawValue)
        }
        self.handle = handle
    }

    deinit {
        ghostty_terminal_free(handle)
    }

    /// Feed raw output bytes (including VT escape sequences) into the emulator.
    public func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buf in
            ghostty_terminal_vt_write(handle, buf.baseAddress, buf.count)
        }
    }

    /// Render the active screen as trimmed plain text.
    public func plainText() throws -> String {
        let formatter = try makePlainFormatter()
        defer { ghostty_formatter_free(formatter) }
        return try formatString(from: formatter)
    }

    /// The active screen split into renderable lines, top to bottom.
    ///
    /// This is the window-free extraction `TerminalSurface` draws and that
    /// `swift test` can assert against a known feed — no AppKit involved.
    public func lines() throws -> [String] {
        let text = try plainText()
        if text.isEmpty { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Private helpers

    private func makePlainFormatter() throws -> GhosttyFormatter {
        // GHOSTTY_INIT_SIZED is a C macro unavailable to Swift, so set `.size` by hand.
        var opts = GhosttyFormatterTerminalOptions()
        opts.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.trim = true

        var formatter: GhosttyFormatter?
        let r = ghostty_formatter_terminal_new(nil, &formatter, handle, opts)
        guard r == GHOSTTY_SUCCESS, let formatter else {
            throw TerminalError(op: "ghostty_formatter_terminal_new", code: r.rawValue)
        }
        return formatter
    }

    private func formatString(from formatter: GhosttyFormatter) throws -> String {
        var buf: UnsafeMutablePointer<UInt8>?
        var len = 0
        let r = ghostty_formatter_format_alloc(formatter, nil, &buf, &len)
        guard r == GHOSTTY_SUCCESS, let buf else {
            throw TerminalError(op: "ghostty_formatter_format_alloc", code: r.rawValue)
        }
        defer { ghostty_free(nil, buf, len) }
        return String(decoding: UnsafeBufferPointer(start: buf, count: len), as: UTF8.self)
    }
}
