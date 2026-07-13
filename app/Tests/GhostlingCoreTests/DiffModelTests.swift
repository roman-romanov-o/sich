import Foundation
import GhostlingCore
import Testing

struct DiffModelTests {
    private let sample = """
    diff --git a/Sources/Thing.swift b/Sources/Thing.swift
    index 111..222 100644
    --- a/Sources/Thing.swift
    +++ b/Sources/Thing.swift
    @@ -1,2 +1,2 @@
    -let title = "Old value"
    +let title = "New value"
     unchanged
    """

    @Test func parsesFilesHunksAndLines() throws {
        let file = try #require(UnifiedDiffParser.parse(sample).first)
        #expect(file.displayPath == "Sources/Thing.swift")
        #expect(file.hunks.count == 1)
        #expect(file.hunks[0].lines.map(\.kind) == [.deletion, .addition, .context])
    }

    @Test func decodesTransportAndStats() throws {
        let encoded = Data(sample.utf8).base64EncodedString()
        let line = Data("""
        {"ghostling_event_type":"turn_diff","session_id":"s1","iteration":2,\
        "cwd":"/repo","diff_base64":"\(encoded)"}
        """.utf8)
        let turn = try #require(TurnDiffNormalizer.normalize(line, arrival: .distantPast))
        #expect(turn.iteration == 2)
        #expect(turn.additions == 1)
        #expect(turn.deletions == 1)
    }

    @Test func highlightsOnlyChangedWords() {
        let result = WordDiff.spans(old: "let value = old", new: "let value = new")
        #expect(result.old.filter(\.changed).map(\.text) == ["old"])
        #expect(result.new.filter(\.changed).map(\.text) == ["new"])
    }
}
