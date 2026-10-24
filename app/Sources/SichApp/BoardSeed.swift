import Foundation
import SichCore

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
    /// `SICH_CARD_ID` (identity binding). The card built for this seed must
    /// reuse it, or the binding points at nothing.
    let cardID: String?
    /// Deterministic duration fixtures for the screenshot harness. Production
    /// live-terminal seeds leave both at zero and start tracking on state changes.
    let accumulatedWorkingTime: TimeInterval
    let currentWorkingTime: TimeInterval

    init(
        sessionID: String, title: String? = nil, projectDir: String, agent: CardAgent,
        state: CardState, scrollback: String,
        commandOverride: [String]? = nil, cardID: String? = nil,
        accumulatedWorkingTime: TimeInterval = 0,
        currentWorkingTime: TimeInterval = 0
    ) {
        self.sessionID = sessionID
        self.title = title
        self.projectDir = projectDir
        self.agent = agent
        self.state = state
        self.scrollback = scrollback
        self.commandOverride = commandOverride
        self.cardID = cardID
        self.accumulatedWorkingTime = max(0, accumulatedWorkingTime)
        self.currentWorkingTime = max(0, currentWorkingTime)
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
    ///   add-task affordance passes a unique id so multiple live terminals
    ///   coexist on the board.
    public static func liveTerminal(
        projectDir: String, sessionID: String = "live-terminal", title: String? = nil,
        cardID: String? = nil, agent: CardAgent = .claude, claudeConfigDir: String? = nil,
        accountEnv: String? = nil
    ) -> BoardSeed {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let id = cardID ?? UUID().uuidString
        let bind = "SICH_CARD_ID=\(shellQuoted(id)) "
        let config = accountEnv
            ?? ClaudeLaunchEnv.configDirExport(claudeConfigDir)
        let path = "PATH=\(shellQuoted(HookInstaller.codexShimPath())):\"$PATH\" "
        let launch = "cd \(shellQuoted(projectDir)) && \(path)\(config)\(bind)exec \(shellQuoted(shell)) -il"
        return BoardSeed(
            sessionID: sessionID, title: title, projectDir: projectDir,
            agent: agent, state: .idle, scrollback: "",
            commandOverride: ["/bin/sh", "-c", launch], cardID: id
        )
    }
}

extension BoardSeed {
    /// A **remote** terminal card: SSH into `spec.host` and attach to (or create) a
    /// tmux session there, so a session running on another machine lives on the board
    /// like any local one. Because tmux survives the SSH drop, closing/re-opening the
    /// card reconnects to the same running session (`-A`). Firewall-clean: the local
    /// executable is `ssh`, and inside tmux the human drives interactively — never
    /// `claude -p`. Flow B.
    public static func remoteTmux(
        spec: RemoteTmuxSpec, sessionID: String? = nil, title: String? = nil,
        cardID: String? = nil, agent: CardAgent = .claude,
        tmuxEnvironment: [(String, String)] = [],
        agentCommand: String? = nil
    ) throws -> BoardSeed {
        // One id: the card's, the pane's, and the one every relayed hook line carries
        // back. Minting it here and dropping it from the argv would leave the far side
        // exporting nothing to join on (US-004 AC-1).
        let id = cardID ?? UUID().uuidString
        let argv = try RemoteTmuxCommand.argv(
            for: spec, cardID: id, tmuxEnvironment: tmuxEnvironment,
            agentCommand: agentCommand)
        let key = try RemoteSessionKey.make(for: spec)
        return BoardSeed(
            sessionID: sessionID ?? key.sessionID,
            // The tmux session name alone — the host already anchors the card as
            // its project label, so repeating it in the title triple-printed the
            // destination on one card face.
            title: title ?? key.session,
            // `projectDir` is a display/label field for a remote card (no local path);
            // show the ssh destination so drill-in and the card subtitle read sensibly.
            projectDir: spec.target,
            agent: agent, state: .idle, scrollback: "",
            commandOverride: argv, cardID: id
        )
    }
}

private func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension BoardSeed {
    /// A representative spread across states — enough to populate the board for a
    /// screenshot and to exercise the attention count (two cards waiting/blocked).
    /// Mirrors the HELM POC's example cards.
    public static let demo: [BoardSeed] = [
        BoardSeed(sessionID: "feat/quota-pools", title: "Aggregate quota across pools", projectDir: "~/quota-aggregation", agent: .claude, state: .running, scrollback: "running tests — 2/5 suites green…", accumulatedWorkingTime: 4_320, currentWorkingTime: 17 * 60),
        BoardSeed(sessionID: "feat/card-schema", title: "Refactor the card schema", projectDir: "~/card-schema-refactor", agent: .claude, state: .blocked, scrollback: "agent paused — decision required: flat vs nested fields?", accumulatedWorkingTime: 3 * 3_600 + 42 * 60),
        BoardSeed(sessionID: "feat/ghostty-focus", title: "Embed Ghostty focus handling", projectDir: "~/ghostty-focus", agent: .claude, state: .done, scrollback: "All 5 suites green — ready for review.", accumulatedWorkingTime: 4 * 3_600 + 12 * 60),
        BoardSeed(sessionID: "feat/oauth-refresh", title: "Add OAuth token refresh", projectDir: "~/auth-service", agent: .codex, state: .waitingForInput, scrollback: "› proceed with token rotation? [y/N]", accumulatedWorkingTime: 54 * 60),
        BoardSeed(sessionID: "feat/settings-panel", title: "Build the settings panel", projectDir: "~/desktop-app", agent: .claude, state: .running, scrollback: "editing SettingsView.swift…", accumulatedWorkingTime: 2 * 3_600, currentWorkingTime: 8 * 60),
        BoardSeed(sessionID: "feat/export-csv", title: "Export reports to CSV", projectDir: "~/reports", agent: .gemini, state: .runningTests, scrollback: "pytest -q — 18 passed", accumulatedWorkingTime: 45 * 60, currentWorkingTime: 32 * 60),
        BoardSeed(sessionID: "feat/keyboard-nav", title: "Keyboard navigation for the board", projectDir: "~/board-ui", agent: .codex, state: .idle, scrollback: "idle — awaiting next instruction"),
    ]
}
