import Foundation
import SichCore
import Testing

/// A Sich launched from inside one of its own cards must not pass that card's
/// binding, or the launching agent's session markers, on to the ptys it spawns.
struct LaunchEnvironmentTests {
    @Test func stripsCardBindingAndAgentSessionMarkers() {
        let inherited = [
            "SICH_CARD_ID": "B7AA30B1-BC44-44D5-89A6-5C3C590DBF8D",
            "CLAUDECODE": "1",
            "CLAUDE_PID": "40577",
            "CLAUDE_EFFORT": "high",
            "CLAUDE_CONFIG_DIR": "/Users/me/.claude-personal",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_SESSION_ID": "d986c856",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "PATH": "/usr/bin",
            "HOME": "/Users/me",
            "SHELL": "/bin/zsh",
            "SICH_E2E": "1",
            "SICH_EVENTS_FILE": "/tmp/events.jsonl",
        ]
        #expect(LaunchEnvironment.inheritedSessionKeys(in: inherited) == [
            "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_SESSION_ID", "CLAUDE_CONFIG_DIR", "CLAUDE_EFFORT", "CLAUDE_PID",
            "SICH_CARD_ID",
        ])
    }

    @Test func scrubRemovesTheVariablesFromTheRealEnvironment() {
        setenv("SICH_CARD_ID", "test-card", 1)
        setenv("CLAUDE_CODE_CHILD_SESSION", "1", 1)
        LaunchEnvironment.scrub()
        #expect(getenv("SICH_CARD_ID") == nil)
        #expect(getenv("CLAUDE_CODE_CHILD_SESSION") == nil)
        #expect(getenv("PATH") != nil, "only session-scoped names go; the rest is untouched")
    }
}
