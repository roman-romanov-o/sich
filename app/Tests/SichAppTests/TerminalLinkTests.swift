import AppKit
import Foundation
import Testing

@testable import SichApp
@testable import SichCore

/// Checklist 18.08, item 9: URLs and file paths in terminal output are highlighted
/// and ⌘-clickable. The detector is pure text→spans; the surface underlines the
/// spans and routes a real ⌘-click through the injectable opener.
@MainActor
@Suite(.serialized)
struct TerminalLinkTests {

    // MARK: - Detector

    @Test("URLs are found with grid-accurate columns; glued punctuation is trimmed")
    func urlDetection() {
        let line = "docs at (https://example.com/a?b=1). done"
        let links = TerminalLinkDetector.links(in: line)
        let url = try! #require(links.first { $0.kind == .url })
        #expect(url.text == "https://example.com/a?b=1", "wrapper ')' and '.' trimmed")
        let cols = Array(line.unicodeScalars)
        let shown = String(String.UnicodeScalarView(cols[url.columns]))
        #expect(shown == url.text, "columns index the exact cells the link occupies")
    }

    @Test("file paths in their common shapes are all linked")
    func filePathShapes() {
        let cases: [(line: String, expected: String)] = [
            ("error in /usr/local/bin/tool, aborting", "/usr/local/bin/tool"),
            ("see ~/notes/todo.md for context", "~/notes/todo.md"),
            ("run ./scripts/build.sh first", "./scripts/build.sh"),
            ("Sources/SichApp/BoardShell.swift:120:5: warning", "Sources/SichApp/BoardShell.swift:120:5"),
            ("main.swift:12: error: missing brace", "main.swift:12"),
        ]
        for (line, expected) in cases {
            let links = TerminalLinkDetector.links(in: line).filter { $0.kind == .file }
            #expect(links.map(\.text) == [expected], "line: \(line) → \(links.map(\.text))")
        }
    }

    @Test("prose stays prose — no links invented in plain text")
    func plainTextIsQuiet() {
        #expect(TerminalLinkDetector.links(in: "just thinking about the design here").isEmpty)
        #expect(TerminalLinkDetector.links(in: "ratio is 3.5 and n/a applies").isEmpty)
        #expect(TerminalLinkDetector.links(in: "").isEmpty)
    }

    @Test("a URL's path segment is not double-reported as a file link")
    func urlWinsOverItsOwnPath() {
        let links = TerminalLinkDetector.links(in: "open https://github.com/a/b/pull/7 now")
        #expect(links.count == 1)
        #expect(links.first?.kind == .url)
    }

    // MARK: - Resolution

    @Test("file spans resolve: ~ expands, :line strips, relative joins the card dir, ghosts stay dead")
    func fileResolution() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("main.swift")
        try Data("x".utf8).write(to: file)

        let absolute = TerminalLink(kind: .file, text: "\(file.path):12:5", columns: 0..<1)
        #expect(TerminalSurface.resolve(absolute, against: nil)?.path == file.path,
                "absolute path opens with the :line:col suffix shed")

        let relative = TerminalLink(kind: .file, text: "main.swift:12", columns: 0..<1)
        #expect(TerminalSurface.resolve(relative, against: dir.path)?.path == file.path,
                "relative path joins the card's project dir")
        #expect(TerminalSurface.resolve(relative, against: nil) == nil,
                "a relative path with no anchor dir cannot open")

        let ghost = TerminalLink(kind: .file, text: "/no/such/file-\(UUID().uuidString)", columns: 0..<1)
        #expect(TerminalSurface.resolve(ghost, against: nil) == nil,
                "another machine's path never opens a wrong local file")

        let url = TerminalLink(kind: .url, text: "https://example.com", columns: 0..<1)
        #expect(TerminalSurface.resolve(url, against: nil)?.absoluteString == "https://example.com")
    }

    // MARK: - Surface interaction (real event, per the interaction-AC rule)

    /// A minimal grid whose first row shows `text`, one scalar per cell.
    private func grid(showing text: String, cols: Int = 80) -> TerminalGrid {
        let scalars = Array(text.unicodeScalars)
        var cells: [TerminalCell] = []
        for col in 0..<cols {
            cells.append(TerminalCell(
                scalar: col < scalars.count ? scalars[col] : nil, fg: nil, bg: nil))
        }
        return TerminalGrid(cols: cols, rows: 1, cells: cells, cursor: nil,
                            defaultFg: nil, defaultBg: nil)
    }

    @Test("a REAL ⌘-click on a shown URL routes it to the opener; a plain click does not")
    func commandClickOpensTheURL() throws {
        let pty = try PTYSession(command: ["/bin/cat"])
        try pty.start()
        defer { pty.terminate() }
        let surface = TerminalSurface(session: pty, fontSize: 20)
        var opened: [URL] = []
        surface.openLink = { opened.append($0) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        surface.frame = window.contentView!.bounds
        window.contentView!.addSubview(surface)
        window.makeKeyAndOrderFront(nil)
        window.contentView!.layoutSubtreeIfNeeded()

        let line = "visit https://example.com/x today"
        surface.installGridForTesting(grid(showing: line))
        let link = try #require(surface.linkForTesting(atCol: 8, row: 0))
        #expect(link.text == "https://example.com/x")

        // Aim at a cell inside the link (the surface's own font metrics), convert
        // to window coords — then dispatch a REAL event through the window.
        let inside = surface.convert(surface.cellCenterForTesting(col: 8, row: 0), to: nil)
        #expect(window.contentView!.hitTest(inside) === surface,
                "the click point lands on the terminal surface")
        func click(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: inside, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        window.sendEvent(click([.command]))
        #expect(opened == [URL(string: "https://example.com/x")!],
                "⌘-click on the highlighted URL opens it")

        window.sendEvent(click([]))
        window.sendEvent(NSEvent.mouseEvent(
            with: .leftMouseUp, location: inside, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!)
        #expect(opened.count == 1, "a plain click starts a selection, never opens")
    }

    @Test("⌘-click on plain text is inert")
    func commandClickOnProseIsInert() throws {
        let pty = try PTYSession(command: ["/bin/cat"])
        try pty.start()
        defer { pty.terminate() }
        let surface = TerminalSurface(session: pty, fontSize: 20)
        var opened: [URL] = []
        surface.openLink = { opened.append($0) }
        surface.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        surface.installGridForTesting(grid(showing: "no links in this sentence"))
        #expect(surface.linkForTesting(atCol: 5, row: 0) == nil)
        surface.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 60, y: 280),
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        #expect(opened.isEmpty)
    }
}
