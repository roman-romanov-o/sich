import Foundation

/// Where the user's own prompts sit in a Claude Code transcript, read off the
/// rendered terminal text. Claude Code echoes each submitted prompt as a row
/// beginning with its prompt marker (`❯ `, `> ` in older builds) followed by the
/// prompt; continuation rows are indented. The live input box uses the same
/// marker, so rows from the cursor's row down are never marks.
public enum TranscriptMarks {
    /// Row indexes into `lines` (top of scrollback = 0) that begin a user prompt.
    /// `cursorRow` is the cursor's row in the same coordinates.
    public static func userPromptRows(in lines: [String], cursorRow: Int) -> [Int] {
        lines.indices.filter { $0 < cursorRow && isPromptEcho(lines[$0]) }
    }

    private static let markers: Set<Character> = ["❯", ">"]
    private static let blanks: Set<Character> = [" ", "\u{00A0}"]

    static func isPromptEcho(_ line: String) -> Bool {
        let rest = line.drop(while: { blanks.contains($0) })
        guard let marker = rest.first, markers.contains(marker) else { return false }
        let afterMarker = rest.dropFirst()
        guard let gap = afterMarker.first, blanks.contains(gap) else { return false }
        return afterMarker.contains(where: { !blanks.contains($0) })
    }
}
