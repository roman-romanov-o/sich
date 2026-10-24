import Foundation
import SichCore
import Testing

@testable import SichApp

/// CARD-STATUS.md proven end to end against the REAL installed `claude` and `codex`
/// CLIs — no mocks, no synthetic hook lines, and no headless `claude -p` (watcher
/// discipline: both agents run interactively inside a real board card's PTY, exactly
/// as the operator does).
///
/// Why this suite exists — the previous real-agent smoke could not be trusted:
///  - it drove `claude -p` / `codex exec`, the HEADLESS path the product never uses,
///    so the interactive lifecycle (the one the board actually watches) was untested;
///  - it asserted at store level with a `validFinal` set wide enough that a wrong
///    resting state still passed.
/// This suite instead:
///  - TYPES the agent command into the card's live login shell (`startClaude:false`)
///    — which is also the manual-launch/app-restart case from CARD-STATUS.md's
///    "Manual launches are first-class" invariant;
///  - asserts at BOARD level: the real card's `ColumnGroup` after the full pipeline
///    (forwarder → events file → SessionsPoller → BoardShell.applySessions);
///  - guards against hollow passes: each phase requires the hook evidence
///    (PreToolUse / Subagent* / Stop counts) proving the agent really did the thing
///    the phase asserts about.
///
/// Opt-in (spends real interactive-pool quota, takes minutes):
///
///     SICH_REAL_AGENT_E2E=1 swift test --filter CardStatusRealAgentE2ETests
///
/// (`app/scripts/real-agent-status-e2e.sh` wraps this.)
@MainActor
@Suite(.serialized, .enabled(if: RealAgentGate.optedIn))
struct CardStatusRealAgentE2ETests {

    // MARK: - Interactive flow, Claude: rules 1, 2, 2.1, 3, 4, 4.1 + subagent

    /// One continuous journey through a single real Claude session (one session
    /// amortizes launch cost across every rule):
    ///  rule 1   — created card, agent not launched → QUEUE
    ///  rule 2   — typed `claude '…'` into the card's shell → WORKING
    ///  rule 2.1 — a real `sleep 90` tool call outlives the injected 45s stall
    ///             threshold → NEEDS YOU, then PostToolUse recovers → WORKING
    ///  rule 3   — Stop at turn end → NEEDS YOU
    ///  rule 4   — manual DONE survives a REAL follow-up agent turn untouched
    ///  rule 4.1 — moved back out of DONE, the next turn re-drives WORKING → NEEDS
    ///             YOU; that turn runs a real Task-tool subagent, and the card stays
    ///             WORKING throughout the child's run (rule 2's subagent clause)
    @Test func claudeJourneyThroughEveryInteractiveRule() throws {
        let h = try RealCardHarness(title: "e2e-claude-journey", stallThreshold: 45)
        defer { h.stop() }

        #expect(h.group() == .queue, "rule 1: an untouched card sits in QUEUE")
        try h.awaitShellReady()

        // The post-sleep generation (20 facts) matters: it widens the PostToolUse→Stop
        // gap to seconds, so the recovery WORKING window is observable at poll cadence.
        // A one-word reply lands PostToolUse and Stop in the same poll batch, where
        // burst dominance collapses straight to the Stop state.
        // The prompt MUST precede --allowedTools: the flag is variadic and swallows
        // every trailing argument as a tool entry (run 2 failed exactly this way —
        // claude launched into an empty composer and only SessionStart ever fired).
        // The stall phase needs one genuinely silent ~90s FOREGROUND tool call, and
        // claude's own harness fights exactly that: foreground `sleep` is blocked
        // outright, so across runs the model (a) answered without running it,
        // (b) set run_in_background: true, and (c) loaded the Monitor tool and set a
        // timer — each time ending the turn instantly and getting woken later, which
        // leaves no silent window for the stall guard. Hence a python sleep (not
        // blocked as foreground) plus explicit bans on every observed escape hatch.
        // Run 7 showed the model DOES honor "never set run_in_background" once
        // foreground execution is actually possible.
        h.launchAgent(
            "claude 'First use the Bash tool to run exactly this one command as a "
                + "single foreground call and wait for it to finish: "
                + "python3 -c \"import time; time.sleep(90)\" — do not skip or "
                + "shorten it, never set run_in_background, and do not use Monitor, "
                + "timers, or any other tool for the wait: make the one Bash call "
                + "and block until it returns. After it completes, write a numbered "
                + "list of 20 short facts about Unix terminals, then end with "
                + "exactly: STALL_DONE' "
                + "--allowedTools 'Bash(python3:*),Task'")
        // UserPromptSubmit proves the agent really took the prompt: PTY live-detection
        // (task-04) can drive WORKING from terminal output alone, so the column check
        // by itself would be a hollow pass.
        try #require(h.wait(120) { h.group() == .working && h.eventCount("UserPromptSubmit") >= 1 },
                     "rule 2: claude never reached WORKING on a real prompt — \(h.debug())")

        // Rule 2.1 — mid-sleep NEEDS YOU. PreToolUse proves the sleep really started
        // (an empty composer stalls the same way — run 2's hollow near-pass); with no
        // PostToolUse and no Stop yet, the tool is still running and the turn has not
        // ended, so this flag can only be the 45s stall guard reacting to real silence.
        try #require(h.wait(120) { h.group() == .needsYou && h.eventCount("PreToolUse") >= 1
                         && h.eventCount("PostToolUse") == 0 && h.eventCount("Stop") == 0 },
                     "rule 2.1: the stall guard never flagged the silent sleep — \(h.debug())")

        // Recovery — the finished tool call + the fact-list generation put the
        // stalled card back to WORKING before the turn ends.
        try #require(h.wait(120) { h.group() == .working && h.eventCount("PostToolUse") >= 1 },
                     "rule 2 recovery: PostToolUse never recovered the stalled card — \(h.debug())")

        // Rule 3 — Stop parks the finished turn in NEEDS YOU.
        try #require(h.wait(120) { h.group() == .needsYou && h.eventCount("Stop") >= 1 },
                     "rule 3: turn end never flagged NEEDS YOU — \(h.debug())")

        // Rule 4: manual DONE is sticky against a real subsequent turn.
        h.move(to: .done)
        let doneMark = h.groupLog.count
        let stopsBeforeDoneTurn = h.eventCount("Stop")
        h.typePrompt("Reply with exactly OK")
        try #require(h.wait(180) { h.eventCount("Stop") > stopsBeforeDoneTurn },
                     "the follow-up turn never ended — \(h.debug())")
        #expect(h.group() == .done, "rule 4: a real agent turn must not move a manually-DONE card")
        #expect(h.groupLog.count == doneMark,
                "rule 4: DONE card transitioned during the turn: \(Array(h.groupLog[doneMark...]))")

        // Rule 4.1 + rule 2 (subagent): move back re-arms the normal rules.
        h.move(to: .idle)
        let stopsBeforeSubTurn = h.eventCount("Stop")
        h.typePrompt(
            "Use the Task tool to launch exactly one subagent that replies with the word OK. "
                + "After it returns, reply with exactly: SUBAGENT_DONE")
        try #require(h.wait(120) { h.group() == .working },
                     "rule 4.1: re-armed card never returned to WORKING — \(h.debug())")
        let subMark = h.groupLog.count
        try #require(h.wait(300) { h.group() == .needsYou && h.eventCount("Stop") > stopsBeforeSubTurn },
                     "the subagent turn never ended — \(h.debug())")
        #expect(h.eventCount("SubagentStart") + h.eventCount("SubagentStop") >= 1,
                "hollow-pass guard: no subagent ran (claude ignored the Task instruction)")
        let subTransitions = Array(h.groupLog[subMark...])
        #expect(subTransitions == [.needsYou],
                "rule 2: waiting-for-subagent must stay WORKING until the turn ends; saw \(subTransitions)")
    }

    // MARK: - Interactive flow, Codex: rules 1, 2, 3

    /// Codex runs the same store/board pipeline (rules 2.1/4/4.1 are agent-agnostic
    /// and proven above), so its journey binds the codex-specific surface: the shim →
    /// TOML-profile hooks → snake_case normalization → the same three columns.
    @Test func codexJourneyQueueWorkingNeedsYou() throws {
        let h = try RealCardHarness(title: "e2e-codex-journey", stallThreshold: 600)
        defer { h.stop() }

        #expect(h.group() == .queue, "rule 1: an untouched card sits in QUEUE")
        try h.awaitShellReady()

        // A long no-tools generation, NOT a one-word reply: codex hook lines carry no
        // timestamp, so an instant UserPromptSubmit+Stop pair read in one poll batch
        // coalesces into a single burst whose dominant event is Stop — the transient
        // WORKING state would never be observable. Real multi-second output keeps the
        // turn open across polls. (First run failed exactly this way on "Reply OK".)
        h.launchAgent(
            "codex 'Write a numbered list of 25 short facts about the moon, "
                + "then end with exactly: DONE. "
                + "Do not run any commands and do not use any tools.'")
        try #require(h.wait(180) { h.group() == .working && h.eventCount("UserPromptSubmit") >= 1 },
                     "rule 2: codex never reached WORKING on a real prompt — \(h.debug())")
        try #require(h.wait(240) { h.group() == .needsYou && h.eventCount("Stop") >= 1 },
                     "rule 3: codex turn end never flagged NEEDS YOU — \(h.debug())")
    }
}

/// Gate: these tests launch real agents and spend real quota — never on by default.
private enum RealAgentGate {
    static let optedIn = ProcessInfo.processInfo.environment["SICH_REAL_AGENT_E2E"] == "1"
}

/// One real board card wired to the full live pipeline:
/// `createSession(startClaude:false)` → a real login shell in a real PTY (with
/// `SICH_CARD_ID` + the shim PATH) → typed agent commands → real hooks →
/// a private events file (via `SICH_EVENTS_FILE`, the same override the
/// forwarder honors) → `SessionsPoller` → `BoardShell.applySessions`.
@MainActor
private final class RealCardHarness {
    let shell: BoardShell
    let card: BoardCard
    let events: URL
    /// Every observed change of the card's column, in order — the journey record.
    private(set) var groupLog: [BoardView.ColumnGroup] = []
    private var poller: SessionsPoller?
    private let priorEventsOverride: String?

    init(title: String, stallThreshold: TimeInterval) throws {
        events = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-card-status-e2e-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: events.path, contents: nil)
        // The card's shell inherits this process's environment, so the override set
        // here reaches the hook forwarder inside the spawned agent — the run is fully
        // isolated from the operator's real ~/.sich/events.jsonl.
        priorEventsOverride = ProcessInfo.processInfo.environment["SICH_EVENTS_FILE"]
        setenv("SICH_EVENTS_FILE", events.path, 1)
        _ = HookInstaller.installClaudeShim()
        _ = HookInstaller.installCodexShim()

        shell = BoardShell(seeds: [])
        shell.buildContentForTesting()
        shell.startSessionPump()   // the always-on drain: a real turn's output must not block
        do {
            card = try #require(
                shell.createSession(title: title, projectDir: Self.repoRoot, startClaude: false),
                "launching the card's login shell failed")
        } catch {
            // The caller's `defer { h.stop() }` never registers on a thrown init, so
            // the process-global override must be unwound here or it leaks into every
            // later test in the process.
            Self.restoreEventsOverride(priorEventsOverride)
            shell.e2eTeardown()
            throw error
        }

        // Backstop disabled (9999): every poll happens inside `wait`, so every column
        // change is recorded. `stallThreshold` is the injected rule-2.1 budget.
        let poller = SessionsPoller(eventsFile: events, interval: 9999,
                                    stallThreshold: stallThreshold) { [weak shell] cards in
            shell?.applySessions(cards)
        }
        poller.start()
        self.poller = poller
    }

    /// Poll → merge → record, at ~4Hz, until the predicate holds or `timeout` passes.
    /// Wall-clock by design: real agents, real latencies, real stall windows.
    @discardableResult
    func wait(_ timeout: TimeInterval, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pollOnce()
            if predicate() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        pollOnce()
        return predicate()
    }

    func group() -> BoardView.ColumnGroup {
        let state = shell.cards.first { $0.id == card.id }?.state ?? .unknown
        return BoardView.ColumnGroup.group(for: state)
    }

    /// Type a line into the card's shell prompt (canonical mode: `\n` submits). The
    /// tty input buffer holds it until the login shell finishes initialising — the
    /// same mechanism the product's own start-claude path relies on.
    func typeShellLine(_ line: String) {
        shell.e2eSend(Array((line + "\n").utf8), into: card)
    }

    /// Launch an agent CLI with the harness's forwarder overrides riding the command
    /// line itself, so every hook the agent (and its subagents) fires inherits them:
    ///  - SICH_EVENTS_FILE — this run's private events file;
    ///  - SICH_EVENTS_MAX_BYTES — rotation OFF for the run: once the forwarder
    ///    rotates the live file to `.1`, every cumulative eventCount() silently
    ///    resets to zero mid-journey while the poller (inode-tailing) keeps moving
    ///    the card.
    func launchAgent(_ command: String) {
        typeShellLine(
            "SICH_EVENTS_FILE='\(events.path)' "
                + "SICH_EVENTS_MAX_BYTES=1073741824 "
                + command)
    }

    /// Prove the login shell is interactive BEFORE the agent command is typed: zsh's
    /// init can tcsetattr(TCSAFLUSH) and DISCARD input buffered during startup, so a
    /// line typed too early can silently vanish. A `touch` probe is idempotent, so it
    /// is retyped until its marker file appears.
    func awaitShellReady(_ timeout: TimeInterval = 45) throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-e2e-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !FileManager.default.fileExists(atPath: marker.path) {
            typeShellLine("touch '\(marker.path)'")
            wait(3) { FileManager.default.fileExists(atPath: marker.path) }
        }
        try #require(FileManager.default.fileExists(atPath: marker.path),
                     "the card's login shell never became interactive — \(debug())")
    }

    /// Type a prompt into the agent's TUI composer, then submit with a carriage
    /// return after a beat (raw mode: Enter is `\r`; the pause lets the TUI ingest
    /// the burst before the submit keystroke).
    func typePrompt(_ text: String) {
        shell.e2eSend(Array(text.utf8), into: card)
        wait(1) { false }
        shell.e2eSend([0x0D], into: card)
    }

    func move(to column: BoardColumn) {
        shell.move(cardID: card.id, to: column)
        recordTick()
    }

    /// How many hook lines with this `hook_event_name` the real agents have emitted.
    func eventCount(_ hookName: String) -> Int {
        eventLines().filter { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let payload = object as? [String: Any] else { return false }
            return payload["hook_event_name"] as? String == hookName
        }.count
    }

    /// Failure-message context for a timed-out phase: where the card is, every column
    /// transition seen so far, how many of each hook event arrived, and the last few
    /// raw lines (which also surface non-hook streams like the JSONL reconciler's).
    func debug() -> String {
        var counts: [String: Int] = [:]
        for line in eventLines() {
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
            let name = (object as? [String: Any])?["hook_event_name"] as? String ?? "<no-hook-name>"
            counts[name, default: 0] += 1
        }
        let tally = counts.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }.joined(separator: " ")
        let tail = eventLines().suffix(6)
            .map { $0.count > 300 ? $0.prefix(300) + "…" : $0[...] }
            .joined(separator: " | ")
        let screen = shell.e2eScreenText(of: card)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(8).joined(separator: " ⏎ ")
        return "group=\(group()), transitions=\(groupLog), events=[\(tally)]; "
            + "screen: «\(screen)»; tail: \(tail)"
    }

    private static func restoreEventsOverride(_ prior: String?) {
        if let prior {
            setenv("SICH_EVENTS_FILE", prior, 1)
        } else {
            unsetenv("SICH_EVENTS_FILE")
        }
    }

    func stop() {
        poller?.stop()
        shell.e2eTeardown()
        Self.restoreEventsOverride(priorEventsOverride)
        // Keep the last run's raw stream (live + any rotated generation) at stable
        // paths — the postmortem artifact for any failure (per-run files deleted).
        let temp = FileManager.default.temporaryDirectory
        for (source, name) in [(events, "sich-e2e-last-events.jsonl"),
                               (events.appendingPathExtension("1"),
                                "sich-e2e-last-events.jsonl.1")] {
            let keep = temp.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: keep)
            try? FileManager.default.copyItem(at: source, to: keep)
            try? FileManager.default.removeItem(at: source)
        }
        try? FileManager.default.removeItem(at: events.appendingPathExtension("offset"))
        print("[e2e] events preserved at \(temp.path)/sich-e2e-last-events.jsonl")
    }

    private func pollOnce() {
        poller?.fireWatchForTesting()
        // The drain parses off-main and applies back on the main actor; pump the run
        // loop so that apply lands BEFORE the journey record (wall-clock is fine
        // here by design — this is the real-agent E2E, already run-loop paced).
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        recordTick()
    }

    private func recordTick() {
        let current = group()
        if groupLog.last != current { groupLog.append(current) }
    }

    /// All lines this run has produced, INCLUDING a rotated-away generation: even
    /// with rotation effectively disabled via launchAgent's overrides, a count that
    /// can silently reset to zero mid-journey must never be a failure mode again.
    private func eventLines() -> [String] {
        let rotated = events.appendingPathExtension("1")
        return [rotated, events].flatMap { url -> [String] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }
    }

    /// The repo root: a directory the operator's claude already trusts, so the real
    /// TUI opens straight into the session instead of a trust prompt.
    private static var repoRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SichAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
            .path
    }
}
