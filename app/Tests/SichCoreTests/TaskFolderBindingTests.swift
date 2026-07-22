import Foundation
import Testing
@testable import SichCore

@Test func taskFolderDefaultsToNilAndSurvivesStateChanges() {
    let unbound = BoardCard(
        sessionID: "old", projectDir: "/project", agent: .claude, flow: .b, state: .idle
    )
    #expect(unbound.taskFolder == nil)

    let bound = BoardCard(
        sessionID: "new", projectDir: "/project", agent: .claude, flow: .a,
        state: .idle, taskFolder: "/project/docs/tasks/../tasks/task-08"
    )
    #expect(bound.with(state: .running).taskFolder == "/project/docs/tasks/task-08")
}
