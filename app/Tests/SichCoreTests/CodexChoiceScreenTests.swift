import SichCore
import Testing

struct CodexChoiceScreenTests {
    @Test func codexChoiceFooterClassifiesAsWaiting() {
        let screen = """
        Which design decisions should we document in this phase?

        1. All 8 (Recommended)
        2. Core 5 only
        3. Blocking 3 only
        4. Type something.

        Enter to select · ↑/↓ to navigate · Esc to cancel
        """

        #expect(CodexChoiceScreen.isWaitingForChoice(screen))
    }

    @Test func questionWithoutCodexFooterDoesNotClassifyAsWaiting() {
        let screen = """
        Which design decisions should we document in this phase?

        The agent is still drafting options and has not opened a choice menu.
        """

        #expect(!CodexChoiceScreen.isWaitingForChoice(screen))
    }
}
