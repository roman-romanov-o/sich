import Foundation
import SichCore
import Testing

/// User-prompt marks are read off the rendered transcript. The fixture is a real
/// Claude Code session's raw terminal output (two prompts, then `/exit`), replayed
/// through the emulator so the rows are exactly what the surface would see.
struct TranscriptMarksTests {
    private func replayFixture() throws -> Terminal {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-code-transcript.vt")
        let terminal = try Terminal(cols: 100, rows: 30)
        terminal.write(Array(try Data(contentsOf: url)))
        return terminal
    }

    @Test("a real Claude Code transcript yields one mark per submitted prompt, none for the input box")
    func realTranscriptMarksEachPrompt() throws {
        let terminal = try replayFixture()
        let lines = try terminal.lines()
        let cursor = terminal.scrollbackRows + terminal.cursorRow
        let marks = TranscriptMarks.userPromptRows(in: lines, cursorRow: cursor)
        let texts = marks.map { lines[$0].trimmingCharacters(in: .whitespaces) }
        #expect(texts == [
            "❯ reply with the single word pong and nothing else",
            "❯ now reply with the single word ping",
            "❯ /exit"
        ])
    }

    @Test("the marker alone (the empty input box, non-breaking space) is not a prompt")
    func emptyInputBoxIsNotAMark() {
        #expect(TranscriptMarks.userPromptRows(in: ["❯\u{00A0}", "❯ ", "> ", "  text"], cursorRow: 10) == [])
    }

    @Test("rows at and below the cursor are the live input, never marks")
    func rowsFromTheCursorDownAreSkipped() {
        let lines = ["❯ first", "answer", "❯ second", "❯ draft being typed", "status"]
        #expect(TranscriptMarks.userPromptRows(in: lines, cursorRow: 3) == [0, 2])
    }

    @Test("older builds' plain '>' marker counts too, indented continuation rows do not")
    func legacyMarkerAndContinuations() {
        let lines = ["> old style prompt", "  continuation line", ">no gap", "⏺ answer"]
        #expect(TranscriptMarks.userPromptRows(in: lines, cursorRow: 10) == [0])
    }
}
