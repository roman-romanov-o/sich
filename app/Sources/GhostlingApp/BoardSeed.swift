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
    let projectDir: String
    let agent: CardAgent
    let flow: CardFlow
    let state: CardState
    /// The scrollback line the fake terminal prints, so a drilled-in card shows
    /// believable content (e.g. the prompt a waiting session is blocked on).
    let scrollback: String

    init(
        sessionID: String, projectDir: String, agent: CardAgent,
        flow: CardFlow, state: CardState, scrollback: String
    ) {
        self.sessionID = sessionID
        self.projectDir = projectDir
        self.agent = agent
        self.flow = flow
        self.state = state
        self.scrollback = scrollback
    }

    /// The shell argv for the fake agent. It prints an honest placeholder banner,
    /// the card's scrollback line, and a hint on how to leave, then idles on `cat`
    /// so the PTY stays live for drill-in. This is a **demo stub** — there is no
    /// live agent behind a seeded card yet (attaching a real interactive session is
    /// its own task). No agentic CLI, no `claude -p` — firewall-clean.
    var command: [String] {
        let banner = "— demo session · no live agent attached —"
        let hint = "(type freely; press Esc or click ‘← board’ to return)"
        let script = "printf '%s\\n\\n%s\\n\\n%s\\n' "
            + "\(shellQuoted(banner)) \(shellQuoted(scrollback)) \(shellQuoted(hint)); exec cat"
        return ["/bin/sh", "-c", script]
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
        BoardSeed(sessionID: "saha/task-03", projectDir: "~/quota-aggregation", agent: .claude, flow: .a, state: .running, scrollback: "it3 · QA · 2/5 stories — running tests…"),
        BoardSeed(sessionID: "saha/task-04", projectDir: "~/card-schema-refactor", agent: .claude, flow: .a, state: .blocked, scrollback: "agent paused — decision required: flat vs nested fields?"),
        BoardSeed(sessionID: "saha/task-05", projectDir: "~/ghostty-focus", agent: .claude, flow: .a, state: .done, scrollback: "DoD passed — 5/5 stories green."),
        BoardSeed(sessionID: "feat/oauth-refresh", projectDir: "~/auth-service", agent: .codex, flow: .b, state: .waitingForInput, scrollback: "› proceed with token rotation? [y/N]"),
        BoardSeed(sessionID: "feat/settings-panel", projectDir: "~/desktop-app", agent: .claude, flow: .b, state: .running, scrollback: "editing SettingsView.swift…"),
        BoardSeed(sessionID: "feat/export-csv", projectDir: "~/reports", agent: .gemini, flow: .b, state: .runningTests, scrollback: "pytest -q — 18 passed"),
        BoardSeed(sessionID: "feat/keyboard-nav", projectDir: "~/board-ui", agent: .codex, flow: .b, state: .idle, scrollback: "idle — awaiting next instruction"),
    ]
}
