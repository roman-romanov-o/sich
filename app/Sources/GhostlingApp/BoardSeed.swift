import Foundation
import GhostlingCore

/// One seeded session for the screenshot/demo harness: a harmless fake-agent
/// command launched in a real PTY (through the pool firewall — never `claude -p`),
/// paired with the ``CardState`` the board should show it in.
///
/// The fake-agent fixture is a plain shell script that prints a believable
/// scrollback and waits — it emulates an agent for the *rendering* harness only;
/// it spends no quota and runs no agentic CLI.
public struct BoardSeed: Sendable {
    let sessionID: String
    /// The human task title shown as the card headline (US-003: a card is a *task*,
    /// not a raw terminal). `nil` falls back to the project-dir leaf.
    let title: String?
    let projectDir: String
    let agent: CardAgent
    let flow: CardFlow
    let state: CardState
    /// The scrollback line the fake terminal prints, so a drilled-in card shows
    /// believable content (e.g. the prompt a waiting session is blocked on).
    let scrollback: String
    /// When set, the exact argv to launch — a **real** interactive session (e.g. the
    /// user's login shell, where they run `claude`). When `nil`, the demo stub below
    /// is used. This is the seam between the screenshot harness (stub) and the
    /// assembled product (a real terminal, DD-001 "become the terminal").
    let commandOverride: [String]?
    /// The pre-minted board-card UUID string baked into the launch command as
    /// `GHOSTLING_CARD_ID` (identity binding). The card built for this seed must
    /// reuse it, or the binding points at nothing.
    let cardID: String?

    init(
        sessionID: String, title: String? = nil, projectDir: String, agent: CardAgent,
        flow: CardFlow, state: CardState, scrollback: String,
        commandOverride: [String]? = nil, cardID: String? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.projectDir = projectDir
        self.agent = agent
        self.flow = flow
        self.state = state
        self.scrollback = scrollback
        self.commandOverride = commandOverride
        self.cardID = cardID
    }

    /// The argv to launch: a real interactive session if one was supplied, else the
    /// demo stub. Either way it goes through the registry's pool firewall — never
    /// `claude -p`.
    var command: [String] { commandOverride ?? demoStubCommand }

    /// The shell argv for the fake agent. It prints an honest placeholder banner,
    /// the card's scrollback line, and a hint on how to leave, then idles on `cat`
    /// so the PTY stays live for drill-in. This is a **demo stub** used only by the
    /// screenshot harness — no agentic CLI, no `claude -p`.
    private var demoStubCommand: [String] {
        let banner = "— demo session · no live agent attached —"
        let hint = "(type freely; press ⌘[ or click ‘← board’ to return)"
        let script = "printf '%s\\n\\n%s\\n\\n%s\\n' "
            + "\(shellQuoted(banner)) \(shellQuoted(scrollback)) \(shellQuoted(hint)); exec cat"
        return ["/bin/sh", "-c", script]
    }

    /// A **real** interactive terminal card: the user's login shell in `projectDir`,
    /// launched through the pool firewall. Drill into it and run `claude` — this is
    /// the app *being* the terminal (DD-001), the daily-usable surface, not a stub.
    /// Flow B (human-launched, interactive/subscription pool).
    ///
    /// - Parameter sessionID: defaults to `live-terminal` (the seeded card); the
    ///   "+ new session" affordance passes a unique id so multiple live terminals
    ///   coexist on the board.
    public static func liveTerminal(
        projectDir: String, sessionID: String = "live-terminal", title: String? = nil,
        cardID: String? = nil
    ) -> BoardSeed {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // `cd` into the project dir first so the shell opens where the work is, then
        // `exec` the login shell so it owns the PTY (no lingering /bin/sh wrapper).
        // Identity binding: GHOSTLING_CARD_ID rides the environment into the shell and
        // any claude run inside it; the hook forwarder stamps it onto every hook line
        // so the board can bind the observed session back to THIS card, even when
        // several task cards share one project dir.
        let id = cardID ?? UUID().uuidString   // every live terminal is bindable
        let bind = "GHOSTLING_CARD_ID=\(shellQuoted(id)) "
        let launch = "cd \(shellQuoted(projectDir)) && \(bind)exec \(shellQuoted(shell)) -il"
        return BoardSeed(
            sessionID: sessionID, title: title, projectDir: projectDir,
            agent: .claude, flow: .b, state: .idle, scrollback: "",
            commandOverride: ["/bin/sh", "-c", launch], cardID: id
        )
    }
}

private func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension BoardSeed {
    /// A representative spread across states and both flows — enough to populate
    /// the board for a screenshot and to exercise the attention count (two cards
    /// waiting/blocked). Mirrors the HELM POC's example cards.
    public static let demo: [BoardSeed] = [
        BoardSeed(sessionID: "saha/task-03", title: "Aggregate quota across pools", projectDir: "~/quota-aggregation", agent: .claude, flow: .a, state: .running, scrollback: "it3 · QA · 2/5 stories — running tests…"),
        BoardSeed(sessionID: "saha/task-04", title: "Refactor the card schema", projectDir: "~/card-schema-refactor", agent: .claude, flow: .a, state: .blocked, scrollback: "agent paused — decision required: flat vs nested fields?"),
        BoardSeed(sessionID: "saha/task-05", title: "Embed Ghostty focus handling", projectDir: "~/ghostty-focus", agent: .claude, flow: .a, state: .done, scrollback: "DoD passed — 5/5 stories green."),
        BoardSeed(sessionID: "feat/oauth-refresh", title: "Add OAuth token refresh", projectDir: "~/auth-service", agent: .codex, flow: .b, state: .waitingForInput, scrollback: "› proceed with token rotation? [y/N]"),
        BoardSeed(sessionID: "feat/settings-panel", title: "Build the settings panel", projectDir: "~/desktop-app", agent: .claude, flow: .b, state: .running, scrollback: "editing SettingsView.swift…"),
        BoardSeed(sessionID: "feat/export-csv", title: "Export reports to CSV", projectDir: "~/reports", agent: .gemini, flow: .b, state: .runningTests, scrollback: "pytest -q — 18 passed"),
        BoardSeed(sessionID: "feat/keyboard-nav", title: "Keyboard navigation for the board", projectDir: "~/board-ui", agent: .codex, flow: .b, state: .idle, scrollback: "idle — awaiting next instruction"),
    ]
}
