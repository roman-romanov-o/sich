import AppKit
import Foundation
import GhostlingCore
import Testing

@testable import GhostlingApp

/// US-001 saha-flow card creation, driven end-to-end by REAL dispatched `NSEvent`s
/// (`window.sendEvent`) on the chooser's ``ChooserButton`` rows — never `performClick`,
/// which merely fires an action and is the interaction-AC-binding-rule trap this repo
/// has shipped broken three times.
private struct CreatingScaffolder: TaskFolderScaffolding {
    let folder: URL

    func create(title: String, projectDirectory: URL, script: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private struct FailingScaffolder: TaskFolderScaffolding {
    func create(title: String, projectDirectory: URL, script: URL) throws -> URL {
        throw TaskScaffoldingError.processFailed(exitCode: 9, message: "scaffold failed")
    }
}

/// Mimics `init_task.sh`: scaffolds the folder AND repoints `.sahaidachny/current-task`
/// at it — the single project-wide pointer whose reuse is the reviewer-flagged hazard
/// behind TC-E2E-001b.
private struct BindingScaffolder: TaskFolderScaffolding {
    let folder: URL

    func create(title: String, projectDirectory: URL, script: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# \(folder.lastPathComponent)\n".write(
            to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let saha = projectDirectory.appendingPathComponent(".sahaidachny", isDirectory: true)
        try FileManager.default.createDirectory(at: saha, withIntermediateDirectories: true)
        try folder.path.write(
            to: saha.appendingPathComponent("current-task"), atomically: true, encoding: .utf8)
        return folder
    }
}

// MARK: - Harness

@MainActor
private func makeHarness(seeds: [BoardSeed] = []) -> (BoardShell, NSView, NSWindow) {
    let shell = BoardShell(seeds: seeds)
    let root = shell.buildContentForTesting()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = root
    // A key, ordered-front window is what makes `NSWindow.sendEvent` actually route a
    // synthetic mouse event to the hit-tested view (it is gated for an offscreen,
    // non-key window — proven in the probe that informed this harness).
    window.makeKeyAndOrderFront(nil)
    return (shell, root, window)
}

/// Dispatch a genuine left-click on a chooser row through the window's own event
/// delivery + real hit-testing — the binding-rule-compliant "real gesture".
@MainActor
private func dispatchClick(on button: ChooserButton, root: NSView, window: NSWindow) throws {
    root.layoutSubtreeIfNeeded()
    let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    let hit = try #require(root.hitTest(center))
    #expect(hit === button, "the chooser row must own the click point, not a pane behind it")
    let event = try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
    window.sendEvent(event)
}

// MARK: - Tests

/// TC-E2E-001 (US-001 AC1/AC3): create-new via a real click binds the card + opens Planning.
@MainActor
@Test func chooserCreateNewEventBindsCardAndShowsPlanningOverlay() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("docs/tasks/task-09-new")
    let (shell, content, window) = makeHarness()
    shell.beginSahaCreation(
        projectDirectory: root,
        script: root.appendingPathComponent("init_task.sh"),
        scaffolder: CreatingScaffolder(folder: folder)
    )

    let chooser = try #require(shell.sahaTaskChooser)
    chooser.setTitleForTesting("New planning task")
    try dispatchClick(on: chooser.createButton, root: content, window: window)

    let card = try #require(shell.cards.first)
    #expect(card.flow == .a)
    #expect(card.taskFolder == folder.path)
    #expect(shell.planningMode.cardID == card.id)
    #expect(shell.planningMode.isHidden == false)
    #expect(shell.boardView.isHidden)
    shell.e2eTeardown()
}

/// TC-E2E-001b (US-001 AC3): creating card B must NOT move card A's binding, even though
/// B's scaffold repoints the project-wide `.sahaidachny/current-task` at task-MM.
@MainActor
@Test func creatingCardBDoesNotBreakCardABinding() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let folderA = root.appendingPathComponent("docs/tasks/task-01-sample-feature")
    let folderB = root.appendingPathComponent("docs/tasks/task-02-other-feature")
    let (shell, content, window) = makeHarness()
    let script = root.appendingPathComponent("init_task.sh")

    // Card A: bound to task-NN; this also writes current-task → task-NN.
    shell.beginSahaCreation(projectDirectory: root, script: script,
                            scaffolder: BindingScaffolder(folder: folderA))
    let chooserA = try #require(shell.sahaTaskChooser)
    chooserA.setTitleForTesting("sample feature")
    try dispatchClick(on: chooserA.createButton, root: content, window: window)
    let cardA = try #require(shell.cards.first)
    #expect(cardA.taskFolder == folderA.path)

    // Card B: bound to task-MM; this REPOINTS current-task → task-MM (the hazard).
    shell.beginSahaCreation(projectDirectory: root, script: script,
                            scaffolder: BindingScaffolder(folder: folderB))
    let chooserB = try #require(shell.sahaTaskChooser)
    chooserB.setTitleForTesting("other feature")
    try dispatchClick(on: chooserB.createButton, root: content, window: window)

    // current-task now points at B, yet A's authoritative `taskFolder` is untouched.
    let pointer = try String(
        contentsOf: root.appendingPathComponent(".sahaidachny/current-task"), encoding: .utf8)
    #expect(pointer == folderB.path)
    let cardANow = try #require(shell.cards.first { $0.id == cardA.id })
    #expect(cardANow.taskFolder == folderA.path, "card A's binding must not follow current-task")

    // Entering Planning Mode on card A still opens task-NN (reads taskFolder, not the pointer).
    shell.returnToBoard()
    shell.enterPlanningModeForTesting(cardANow)
    #expect(shell.planningMode.cardID == cardA.id)
    #expect(cardANow.taskFolder == folderA.path)
    shell.e2eTeardown()
}

/// TC-E2E-002: an existing folder selected via a real click binds the card + opens Planning.
@MainActor
@Test func chooserExistingFolderEventBindsCardAndShowsPlanningOverlay() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("docs/tasks/task-03-existing")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let (shell, content, window) = makeHarness()
    shell.beginSahaCreation(
        projectDirectory: root,
        script: root.appendingPathComponent("init_task.sh"),
        scaffolder: CreatingScaffolder(folder: folder)
    )

    let chooser = try #require(shell.sahaTaskChooser)
    let existing = try #require(chooser.existingButtons.first)
    try dispatchClick(on: existing, root: content, window: window)

    let card = try #require(shell.cards.first)
    #expect(card.taskFolder == folder.path)
    #expect(shell.planningMode.cardID == card.id)
    #expect(shell.planningMode.isHidden == false)
    shell.e2eTeardown()
}

/// TC-E2E-003: a failed scaffold surfaces and never silently binds an unbound card.
@MainActor
@Test func scaffoldFailureIsVisibleAndDoesNotCreateCard() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let (shell, content, window) = makeHarness()
    shell.beginSahaCreation(
        projectDirectory: root,
        script: root.appendingPathComponent("init_task.sh"),
        scaffolder: FailingScaffolder()
    )

    let chooser = try #require(shell.sahaTaskChooser)
    chooser.setTitleForTesting("Will fail")
    try dispatchClick(on: chooser.createButton, root: content, window: window)

    #expect(shell.cards.isEmpty)
    #expect(chooser.errorLabel.isHidden == false)
    #expect(shell.planningMode.isHidden)
    shell.e2eTeardown()
}

/// A terminal-launch failure on the existing-folder path also surfaces, no card added.
@MainActor
@Test func terminalLaunchFailureIsVisibleAndDoesNotCreateCard() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("docs/tasks/task-01-existing")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let (shell, content, window) = makeHarness()
    shell.launchOverrideForTesting = { _ in nil }
    shell.beginSahaCreation(
        projectDirectory: root,
        script: root.appendingPathComponent("init_task.sh"),
        scaffolder: CreatingScaffolder(folder: folder)
    )

    let chooser = try #require(shell.sahaTaskChooser)
    let existing = try #require(chooser.existingButtons.first)
    try dispatchClick(on: existing, root: content, window: window)

    #expect(shell.cards.isEmpty)
    #expect(chooser.errorLabel.stringValue.contains("terminal"))
    #expect(shell.planningMode.isHidden)
    shell.e2eTeardown()
}

/// Interactive Codex creation labels the owned card as Codex and writes the `codex`
/// launch line into the fresh login-shell PTY.
@MainActor
@Test func codexInteractiveCreationStartsCodexAndLabelsCard() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let (shell, _, _) = makeHarness()
    var input: [UInt8] = []
    shell.launchOverrideForTesting = { seed in
        let pty = try! PTYSession(command: ["/bin/cat"])
        try! pty.start()
        pty.onInput = { input += $0 }
        return Session(
            projectDir: seed.projectDir,
            agentType: AgentType(rawValue: seed.agent.rawValue) ?? .shell,
            flowTag: .interactive,
            pty: pty
        )
    }

    let card = try #require(shell.createSession(
        title: "Use Codex",
        projectDir: root.path,
        autoStartAgent: .codex
    ))

    #expect(card.agent == .codex)
    #expect(String(decoding: input, as: UTF8.self) == BoardShell.startCodexCommand())
    shell.e2eTeardown()
}

/// TC-E2E-006 (US-001 edge case 1): no `docs/tasks/` folder at all → the chooser offers
/// only "create new" (no existing rows, no crash), and create-new works from the clean slate.
@MainActor
@Test func noTasksFolderShowsOnlyCreateNew() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let (shell, content, window) = makeHarness()
    shell.beginSahaCreation(
        projectDirectory: root,   // no docs/tasks/ underneath
        script: root.appendingPathComponent("init_task.sh"),
        scaffolder: CreatingScaffolder(folder: root.appendingPathComponent("docs/tasks/task-01-fresh"))
    )

    let chooser = try #require(shell.sahaTaskChooser)
    #expect(chooser.existingButtons.isEmpty, "no task folders → no existing-folder rows")

    // Create-new is the only path, and it works from the clean slate.
    chooser.setTitleForTesting("fresh")
    try dispatchClick(on: chooser.createButton, root: content, window: window)
    let card = try #require(shell.cards.first)
    #expect(card.taskFolder == root.appendingPathComponent("docs/tasks/task-01-fresh").path)
    #expect(shell.planningMode.isHidden == false)
    shell.e2eTeardown()
}

/// TC-E2E-007 (US-001 edge case 3): a bare folder with no README/status markers still binds,
/// and its progress chip reads "unknown" — never a fabricated fraction or a crash.
@MainActor
@Test func bareFolderBindsWithUnknownProgressChip() throws {
    let root = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let bare = root.appendingPathComponent("docs/tasks/task-09-bare")
    try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
    let (shell, content, window) = makeHarness()
    shell.beginSahaCreation(
        projectDirectory: root,
        script: root.appendingPathComponent("init_task.sh"),
        scaffolder: CreatingScaffolder(folder: bare)
    )

    let chooser = try #require(shell.sahaTaskChooser)
    let existing = try #require(chooser.existingButtons.first)
    #expect(existing.stringValue.contains("unknown"), "bare folder chip must read the unknown state")

    try dispatchClick(on: existing, root: content, window: window)
    let card = try #require(shell.cards.first)
    #expect(card.taskFolder == bare.path)   // binding still completes
    #expect(shell.planningMode.cardID == card.id)
    shell.e2eTeardown()
}

private func temporaryProject() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
