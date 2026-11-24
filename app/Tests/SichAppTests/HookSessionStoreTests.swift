import Foundation
import SichCore
import Testing

@testable import SichApp

/// Reconciler-correctness invariants the live board depends on (US-002). Two bound
/// symbols live here:
///
/// - **TC-UNIT-012** — freshest state wins by `updatedAt`: when several agent sessions
///   have run in ONE project dir, the owned card must track what is *live now* by
///   observation time, so a STALE `blocked`/`waiting` from a finished run can never
///   out-rank a FRESH `running`. Ordering is by `updatedAt` (already on the model), no
///   `seq`/`ppid`.
/// - **TC-UNIT-014** — a clean `SessionEnd` puts the session at rest immediately
///   (resumable `.idle`, never auto-`done`), while a hard-killed run with no
///   `SessionEnd` still recovers via the stall guard: silence past the threshold
///   routes to NEEDS YOU (rule 2.1).
///
/// Deterministic throughout: every timestamp is injected (epoch + offsets), never the
/// wall clock — the anti-flake rule (GridTextTests fromPTY PTY-EOF precedent).
@MainActor
struct HookSessionStoreTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func ownedShell() -> BoardShell {
        let seed = BoardSeed(
            sessionID: "live-terminal", projectDir: "/work",
            agent: .claude, state: .idle, scrollback: "ready"
        )
        let shell = BoardShell(seeds: [seed])
        _ = shell.buildContentForTesting()
        return shell
    }

    private func run(_ id: String, _ state: CardState, at: Date) -> BoardCard {
        BoardCard(sessionID: id, projectDir: "/work", agent: .claude, state: state, updatedAt: at)
    }

    private func normalized(_ json: String, arrival: Date) -> SignalEvent {
        HookNormalizer.normalize(Data(json.utf8), arrival: arrival)!
    }

    // MARK: - TC-UNIT-012: freshest state wins by updatedAt

    @Test func updatedAtTiebreak_freshWins() throws {
        let shell = ownedShell()   // owned card: dir "/work", state .idle

        // Two agent sessions have run in this ONE terminal: an OLD blocked/waiting run
        // and a FRESHER running one. By activity-rank alone `blocked` (5) out-ranks
        // `running` (3) — the stale-out-ranks-fresh bug. `updatedAt` must decide first.
        let stale = run("claude-old", .blocked, at: base)
        let fresh = run("claude-new", .running, at: base.addingTimeInterval(10))
        shell.applySessions([stale, fresh])

        let owned = try #require(shell.cards.first { $0.sessionID == "live-terminal" })
        #expect(owned.state == .running,
                "the freshest observation must win — a stale blocked run cannot out-rank a fresh running one")
    }

    /// CARD-STATUS.md rule 1: launching an agent is not starting work. Creating a
    /// card auto-launches claude, and that SessionStart alone must leave the card in
    /// QUEUE — only the first submitted prompt moves it to WORKING.
    @Test func freshSessionStaysQueuedUntilFirstPrompt() {
        let store = HookSessionStore(stallThreshold: 30)
        store.ingest([normalized(#"{"hook_event_name":"SessionStart","session_id":"fresh"}"#,
                                 arrival: base)])
        #expect(store.entry(for: "fresh")?.state == .idle,
                "a launched-but-unprompted claude has not started work (rule 1)")
        store.ingest([normalized(#"{"hook_event_name":"UserPromptSubmit","session_id":"fresh"}"#,
                                 arrival: base.addingTimeInterval(2))])
        #expect(store.entry(for: "fresh")?.state == .running)
    }

    // MARK: - TC-UNIT-014: sessionEnd closes now; hard-kill recovers via the stall guard

    @Test func sessionEnd_closesNow_hardKillDecays() {
        let store = HookSessionStore(stallThreshold: 30)

        // A clean SessionEnd hook puts the session at rest IMMEDIATELY — no 30s
        // wait. `.idle`, NOT `.done`: DONE is manual-only (CARD-STATUS.md rule 4),
        // and app restarts `claude --resume` the SAME session id, so the rest must
        // be resumable. The timestamps are 2s apart (a separate coalesce burst).
        store.ingest([
            normalized(#"{"hook_event_name":"SessionStart","session_id":"graceful"}"#,
                       arrival: base),
            normalized(#"{"hook_event_name":"SessionEnd","session_id":"graceful"}"#,
                       arrival: base.addingTimeInterval(2)),
        ])
        #expect(store.entry(for: "graceful")?.state == .idle,
                "a closed session rests in QUEUE, resumable — never auto-done")
        // …and it stays at rest: a later sweep does not stall an idle session.
        store.sweepStale(now: base.addingTimeInterval(3))
        #expect(store.entry(for: "graceful")?.state == .idle)

        // A hard-killed run just stops POSTing — no SessionEnd. It is NOT flagged on
        // the next poll (still within the stall budget)…
        store.ingest([
            normalized(#"{"hook_event_name":"PreToolUse","session_id":"killed"}"#,
                       arrival: base),
        ])
        store.sweepStale(now: base.addingTimeInterval(5))
        #expect(store.entry(for: "killed")?.state == .running)
        // …but the stall guard (CARD-STATUS.md rule 2.1) reaps it once silence passes
        // the threshold: a dead loop needs the operator's eyes → NEEDS YOU.
        store.sweepStale(now: base.addingTimeInterval(31))
        #expect(store.entry(for: "killed")?.state == .waitingForInput)
    }

    // MARK: - Compaction is WORK, never NEED YOU (checklist item 5)

    /// A manual `/compact` is typed exactly on a Stop-ended card: the card must show
    /// WORKING while claude rewrites its context (not NEED YOU, and no stall flip),
    /// then return to the truthful NEED YOU when the re-emitted SessionStart closes
    /// the parenthesis — with the turn latch intact, so a replayed tool line still
    /// cannot re-open the ended turn but the operator's own prompt does.
    @Test func manualCompactShowsWorkingThenRestoresThePromptWait() {
        let store = HookSessionStore(stallThreshold: 30)
        store.ingest([normalized(#"{"hook_event_name":"Stop","session_id":"s"}"#,
                                 arrival: base)])
        #expect(store.entry(for: "s")?.state == .waitingForInput)

        store.ingest([normalized(#"{"hook_event_name":"PreCompact","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(10))])
        #expect(store.entry(for: "s")?.state == .running,
                "compacting is work, not a request for the operator")
        store.sweepStale(now: base.addingTimeInterval(35))
        #expect(store.entry(for: "s")?.state == .running,
                "an in-flight compaction inside the stall budget is not a stall")

        store.ingest([normalized(#"{"hook_event_name":"SessionStart","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(40))])
        #expect(store.entry(for: "s")?.state == .waitingForInput,
                "compaction done → claude is again waiting on the operator")
        store.ingest([normalized(#"{"hook_event_name":"PostToolUse","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(45))])
        #expect(store.entry(for: "s")?.state == .waitingForInput,
                "the restored turn latch still blocks replayed tool lines (US-008 AC-1)")
        store.ingest([normalized(#"{"hook_event_name":"UserPromptSubmit","session_id":"s"}"#,
                                 arrival: base.addingTimeInterval(50))])
        #expect(store.entry(for: "s")?.state == .running)
    }

    /// Auto-compact fires mid-turn: WORKING before, during, and after — and the
    /// completing SessionStart must not disturb the running state (it restores
    /// `running`, the pre-compaction memory, not QUEUE).
    @Test func autoCompactMidTurnStaysWorkingThroughout() {
        let store = HookSessionStore(stallThreshold: 30)
        for (offset, event) in [
            (0.0, "UserPromptSubmit"), (5.0, "PreCompact"),
            (10.0, "SessionStart"), (15.0, "PreToolUse"),
        ] {
            store.ingest([normalized(
                #"{"hook_event_name":"\#(event)","session_id":"auto"}"#,
                arrival: base.addingTimeInterval(offset))])
            #expect(store.entry(for: "auto")?.state == .running,
                    "\(event) must leave a mid-turn compaction WORKING")
        }
    }

    /// A SessionStart with NO pending compaction keeps its long-standing neutrality:
    /// a signal between PreCompact and SessionStart cancels the restore memory, so a
    /// later resume cannot be hijacked into a stale state.
    @Test func interveningSignalCancelsTheCompactionRestore() {
        let store = HookSessionStore(stallThreshold: 30)
        store.ingest([normalized(#"{"hook_event_name":"Stop","session_id":"c"}"#,
                                 arrival: base)])
        store.ingest([normalized(#"{"hook_event_name":"PreCompact","session_id":"c"}"#,
                                 arrival: base.addingTimeInterval(5))])
        // The operator types a real prompt before compaction reports completion:
        // the prompt wins, and the SessionStart that follows must stay neutral
        // (running survives) instead of restoring the remembered prompt-wait.
        store.ingest([normalized(#"{"hook_event_name":"UserPromptSubmit","session_id":"c"}"#,
                                 arrival: base.addingTimeInterval(8))])
        store.ingest([normalized(#"{"hook_event_name":"SessionStart","session_id":"c"}"#,
                                 arrival: base.addingTimeInterval(12))])
        #expect(store.entry(for: "c")?.state == .running,
                "a cancelled restore must not drag the card back to NEED YOU")
    }

    // MARK: - Background parenthesis (CARD-STATUS.md rule 2.3)

    /// The operator report: a backgrounded subagent kept working after the main
    /// turn parked, and the card flipped to NEEDS YOU anyway. Sequence taken
    /// verbatim from a live events.jsonl — the Stop payload itself declares the
    /// still-running child in `background_tasks`, so the card must stay WORKING
    /// until the FINAL Stop whose payload reports the background drained.
    @Test func stopWithRunningBackgroundTaskStaysWorking() {
        let store = HookSessionStore(stallThreshold: 600)
        let running = #"[{"id":"bg1","type":"subagent","status":"running"}]"#
        for (offset, json) in [
            (0.0, #"{"hook_event_name":"UserPromptSubmit","session_id":"bg"}"#),
            (2.0, #"{"hook_event_name":"SubagentStart","session_id":"bg","agent_id":"bg1"}"#),
            (5.0, #"{"hook_event_name":"Stop","session_id":"bg","background_tasks":\#(running)}"#),
        ] {
            store.ingest([normalized(json, arrival: base.addingTimeInterval(offset))])
        }
        #expect(store.entry(for: "bg")?.state == .running,
                "a Stop that leaves a background subagent running parked the prompt, not the work")

        // The child's own tool calls keep flowing after the parked Stop — they must
        // not be swallowed by the turn latch (no turn ended: nothing was latched).
        store.ingest([normalized(
            #"{"hook_event_name":"PreToolUse","session_id":"bg","agent_id":"bg1","tool_name":"Read"}"#,
            arrival: base.addingTimeInterval(10))])
        #expect(store.entry(for: "bg")?.state == .running)

        // The ~60s idle nudge fires while the REPL sits parked ("Claude is waiting
        // for your input"). Its payload carries no background_tasks — the store's
        // remembered parenthesis must mask it.
        store.ingest([normalized(
            #"{"hook_event_name":"Notification","session_id":"bg","notification_type":"idle_prompt"}"#,
            arrival: base.addingTimeInterval(70))])
        #expect(store.entry(for: "bg")?.state == .running,
                "an idle nudge inside the background parenthesis is not an operator wait")

        // Child finishes (its SubagentStop lists ITSELF as running — excluded), the
        // root loop resumes, and the FINAL Stop lands with the background drained:
        // now NEEDS YOU is the truth, and the turn latch arms as usual.
        let selfOnly = #"[{"id":"bg1","type":"subagent","status":"running"}]"#
        for (offset, json) in [
            (80.0, #"{"hook_event_name":"SubagentStop","session_id":"bg","agent_id":"bg1","background_tasks":\#(selfOnly)}"#),
            (85.0, #"{"hook_event_name":"PostToolUse","session_id":"bg","tool_name":"Read"}"#),
            (90.0, #"{"hook_event_name":"Stop","session_id":"bg","background_tasks":[]}"#),
        ] {
            store.ingest([normalized(json, arrival: base.addingTimeInterval(offset))])
        }
        #expect(store.entry(for: "bg")?.state == .waitingForInput,
                "the final Stop (background drained) is the real turn end")
        store.ingest([normalized(
            #"{"hook_event_name":"PreToolUse","session_id":"bg","tool_name":"Bash"}"#,
            arrival: base.addingTimeInterval(95))])
        #expect(store.entry(for: "bg")?.state == .waitingForInput,
                "after the real turn end the replay guard is back in force (US-008 AC-1)")
    }

    /// The operator report: the "Research case for Fund" card parked on four
    /// backgrounded `codex exec` / `cursor-agent` runs it was explicitly waiting on,
    /// and showed NEEDS YOU. An awaited shell job is background work like a
    /// subagent — WORKING — and, since a shell emits no hooks while it runs, the
    /// stall guard must not reap the silence either. The drained Stop ends the turn.
    @Test func stopWithAwaitedBackgroundJobStaysWorkingPastTheStallBudget() {
        let store = HookSessionStore(stallThreshold: 600)
        let jobs = #"[{"id":"bfkrjsvny","type":"shell","status":"running","command":"codex exec -s read-only - < prompt.md"}]"#
        for (offset, json) in [
            (0.0, #"{"hook_event_name":"UserPromptSubmit","session_id":"job"}"#),
            (2.0, #"{"hook_event_name":"PostToolUse","session_id":"job","tool_name":"Bash"}"#),
            (5.0, #"{"hook_event_name":"Stop","session_id":"job","background_tasks":\#(jobs)}"#),
            (70.0, #"{"hook_event_name":"Notification","session_id":"job","notification_type":"idle_prompt"}"#),
        ] {
            store.ingest([normalized(json, arrival: base.addingTimeInterval(offset))])
        }
        #expect(store.entry(for: "job")?.state == .running,
                "a Stop that leaves an awaited background job running parked the prompt, not the work")
        store.sweepStale(now: base.addingTimeInterval(3600))
        #expect(store.entry(for: "job")?.state == .running,
                "a silent awaited job is the wait itself, not a stall")

        // The job's completion re-invokes the agent; its final Stop drains the list.
        for (offset, json) in [
            (3700.0, #"{"hook_event_name":"PreToolUse","session_id":"job","tool_name":"Read"}"#),
            (3710.0, #"{"hook_event_name":"Stop","session_id":"job","background_tasks":[]}"#),
        ] {
            store.ingest([normalized(json, arrival: base.addingTimeInterval(offset))])
        }
        #expect(store.entry(for: "job")?.state == .waitingForInput,
                "the final Stop (background drained) is the real turn end")
    }

    /// A background shell the command check can't place (an app launched with
    /// `swift run`, a server behind a script) parks the turn until the live probe
    /// finds it is a long-lived service. Then the parked Stop was a real turn end:
    /// NEEDS YOU, with the turn latch armed exactly as that Stop would have.
    @Test func probedServiceEndsTheParkedTurn() {
        let store = HookSessionStore(stallThreshold: 600)
        let tasks = #"[{"id":"app1","type":"shell","status":"running","command":"swift run Demo"},{"id":"job1","type":"shell","status":"running","command":"make test"}]"#
        for (offset, json) in [
            (0.0, #"{"hook_event_name":"UserPromptSubmit","session_id":"svc"}"#),
            (5.0, #"{"hook_event_name":"Stop","session_id":"svc","background_tasks":\#(tasks)}"#),
        ] {
            store.ingest([normalized(json, arrival: base.addingTimeInterval(offset))])
        }
        #expect(store.entry(for: "svc")?.state == .running)
        #expect(Set(store.shellsToProbe.map(\.taskID)) == ["app1", "job1"])

        // The app turns out to be a service — but the test job is still awaited.
        store.markServices([.init(sessionID: "svc", taskID: "app1")], now: base.addingTimeInterval(15))
        #expect(store.entry(for: "svc")?.state == .running,
                "an awaited job is still running alongside the service")
        #expect(store.shellsToProbe.map(\.taskID) == ["job1"], "a known service is not re-probed")

        // The job finishes; the agent's next turn leaves only the app running.
        let appOnly = #"[{"id":"app1","type":"shell","status":"running","command":"swift run Demo"}]"#
        for (offset, json) in [
            (60.0, #"{"hook_event_name":"UserPromptSubmit","session_id":"svc"}"#),
            (65.0, #"{"hook_event_name":"Stop","session_id":"svc","background_tasks":\#(appOnly)}"#),
        ] {
            store.ingest([normalized(json, arrival: base.addingTimeInterval(offset))])
        }
        #expect(store.entry(for: "svc")?.state == .waitingForInput,
                "a Stop leaving only a known service running is a real turn end")
        #expect(store.shellsToProbe.isEmpty)
    }

    /// The probe usually lands AFTER the Stop (a server binds its port seconds
    /// later): marking the last awaited shell a service flips the parked card.
    @Test func lateServiceVerdictFlipsTheParkedCardAndLatches() {
        let store = HookSessionStore(stallThreshold: 600)
        let app = #"[{"id":"app1","type":"shell","status":"running","command":"./build/Demo.app/Contents/MacOS/Demo"}]"#
        for (offset, json) in [
            (0.0, #"{"hook_event_name":"UserPromptSubmit","session_id":"late"}"#),
            (5.0, #"{"hook_event_name":"Stop","session_id":"late","background_tasks":\#(app)}"#),
        ] {
            store.ingest([normalized(json, arrival: base.addingTimeInterval(offset))])
        }
        #expect(store.entry(for: "late")?.state == .running)
        store.markServices([.init(sessionID: "late", taskID: "app1")], now: base.addingTimeInterval(20))
        #expect(store.entry(for: "late")?.state == .waitingForInput)
        // Latched like any turn end: a straggling tool hook does not revive it.
        store.ingest([normalized(
            #"{"hook_event_name":"PreToolUse","session_id":"late","tool_name":"Bash"}"#,
            arrival: base.addingTimeInterval(25))])
        #expect(store.entry(for: "late")?.state == .waitingForInput)
    }

    /// Only a turn that ENDED into the parenthesis is parked: a mid-turn payload
    /// listing a running shell (a SubagentStop) must neither be probed nor flipped.
    @Test func midTurnShellIsNotParked() {
        let store = HookSessionStore(stallThreshold: 600)
        let shell = #"[{"id":"j1","type":"shell","status":"running","command":"make test"}]"#
        for (offset, json) in [
            (0.0, #"{"hook_event_name":"UserPromptSubmit","session_id":"mid"}"#),
            (3.0, #"{"hook_event_name":"SubagentStop","session_id":"mid","agent_id":"x","background_tasks":\#(shell)}"#),
        ] {
            store.ingest([normalized(json, arrival: base.addingTimeInterval(offset))])
        }
        #expect(store.shellsToProbe.isEmpty)
        store.markServices([.init(sessionID: "mid", taskID: "j1")], now: base.addingTimeInterval(10))
        #expect(store.entry(for: "mid")?.state == .running, "the turn itself is still running")
    }

    /// A remote session's processes live on another machine: never probed locally.
    @Test func remoteParkedShellIsNotProbed() {
        let store = HookSessionStore(stallThreshold: 600)
        let shell = #"[{"id":"j1","type":"shell","status":"running","command":"make test"}]"#
        store.ingest([normalized(
            #"{"hook_event_name":"Stop","session_id":"rem","sich_host":"box","background_tasks":\#(shell)}"#,
            arrival: base)])
        #expect(store.entry(for: "rem", host: "box")?.state == .running)
        #expect(store.shellsToProbe.isEmpty)
    }

    /// The operator report: a remote card sat in WORKING after the agent had
    /// answered. Its Stop listed a backgrounded SHELL (a dev server that never
    /// exits) as `running`, and the parenthesis masked both the Stop and the idle
    /// nudge. A shell is not a child the turn waits on — this sequence, verbatim
    /// from the far side's events.jsonl, must route NEEDS YOU.
    @Test func stopWithOnlyABackgroundShellIsATurnEnd() {
        let store = HookSessionStore(stallThreshold: 600)
        let server = #"[{"id":"bpws0wrz7","type":"shell","status":"running","description":"Start Metro dev server","command":"npx expo start"}]"#
        for (offset, json) in [
            (0.0, #"{"hook_event_name":"UserPromptSubmit","session_id":"rm"}"#),
            (2.0, #"{"hook_event_name":"PostToolUse","session_id":"rm","tool_name":"Bash"}"#),
            (5.0, #"{"hook_event_name":"Stop","session_id":"rm","background_tasks":\#(server)}"#),
        ] {
            store.ingest([normalized(json, arrival: base.addingTimeInterval(offset))])
        }
        #expect(store.entry(for: "rm")?.state == .waitingForInput,
                "a Stop that leaves only a background shell running is a real turn end")
        store.ingest([normalized(
            #"{"hook_event_name":"Notification","session_id":"rm","notification_type":"idle_prompt"}"#,
            arrival: base.addingTimeInterval(70))])
        #expect(store.entry(for: "rm")?.state == .waitingForInput)
    }

    /// A plain Stop (no background_tasks field at all — pre-background-agent Claude)
    /// and a plain idle nudge keep today's behavior: straight to NEEDS YOU.
    @Test func plainStopAndIdleNudgeStillPark() {
        let store = HookSessionStore(stallThreshold: 600)
        store.ingest([normalized(#"{"hook_event_name":"UserPromptSubmit","session_id":"p"}"#,
                                 arrival: base)])
        store.ingest([normalized(#"{"hook_event_name":"Stop","session_id":"p"}"#,
                                 arrival: base.addingTimeInterval(5))])
        #expect(store.entry(for: "p")?.state == .waitingForInput)

        store.ingest([normalized(#"{"hook_event_name":"UserPromptSubmit","session_id":"n"}"#,
                                 arrival: base)])
        store.ingest([normalized(
            #"{"hook_event_name":"Notification","session_id":"n","notification_type":"idle_prompt"}"#,
            arrival: base.addingTimeInterval(5))])
        #expect(store.entry(for: "n")?.state == .waitingForInput,
                "an idle nudge with no background parenthesis is a real operator wait")
    }
}
