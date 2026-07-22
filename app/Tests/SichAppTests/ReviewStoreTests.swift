import Foundation
import SichCore
import Testing

struct ReviewStoreTests {
    /// The whole review loop in one flow: comment → persist across reload → compose a
    /// SINGLE-line draft (a newline would submit into the live pty) → sent drains queue.
    @Test func reviewStatePersistsAndDraftIsSingleLine() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let store = ReviewStore(taskFolder: folder)
        store.approve("US-001-first.md")
        store.addComment(file: "US-002-second.md", text: "  split the\nAC into two  ")
        store.addComment(file: "US-002-second.md", text: "   ")   // ignored

        let reloaded = ReviewStore(taskFolder: folder)
        #expect(reloaded.isApproved("US-001-first.md"))
        #expect(reloaded.comments(for: "US-002-second.md").count == 1)

        let draft = try #require(
            FeedbackDraft.compose(command: "/saha:stories", comments: reloaded.queued)
        )
        #expect(draft == "/saha:stories revise per review: 1) US-002-second: split the AC into two")
        #expect(!draft.contains("\n"))

        reloaded.markQueuedSent()
        #expect(reloaded.queued.isEmpty)
        #expect(FeedbackDraft.compose(command: "/saha:stories", comments: reloaded.comments) == nil)
    }
}
