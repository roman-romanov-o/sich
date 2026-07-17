import Foundation
import GhostlingCore
import Testing

/// The hook normalizer's classification of the "Claude needs you" signals (US-002
/// AC#3 / TC-UNIT-013). A real Claude Code `Notification` hook (a permission prompt or
/// idle nudge) is a POSITIVE attention signal — it must normalize to
/// `permissionRequest` and reconcile to a `waitingForInput` state that routes the
/// operator's attention, never fall through to `unknown` (which would silently drop the
/// "needs you" badge).
///
/// Pure parse over already-received bytes: spawns nothing, opens no socket, injects the
/// clock (`arrival`) so a timestamp-less payload is deterministic.
struct HookNormalizerTests {
    private let arrival = Date(timeIntervalSince1970: 1_750_000_000)

    private func normalize(_ json: String) -> SignalEvent? {
        HookNormalizer.normalize(Data(json.utf8), arrival: arrival)
    }

    // MARK: - TC-UNIT-013: permission hook → needs-attention

    @Test func permissionHook_setsAttention() throws {
        // The real Claude Code permission-prompt hook name is `Notification`.
        let event = try #require(
            normalize(#"{"hook_event_name":"Notification","session_id":"S","cwd":"/repo"}"#))
        #expect(event.kind == .permissionRequest,
                "a permission/notification hook must classify positively, not as unknown")

        // …and it reconciles to a waiting state that routes attention (the "needs you"
        // signal the header counts).
        let store = HookSessionStore()
        store.ingest([event])
        let entry = try #require(store.entry(for: "S"))
        #expect(entry.state == .waitingForInput)
        #expect(entry.state.needsAttention)
    }

    @Test func codexSessionStartIsIdleUntilPromptSubmit() throws {
        let start = try #require(
            normalize(#"{"hook_event_name":"SessionStart","ghostling_agent":"codex","session_id":"C","cwd":"/repo"}"#))
        #expect(start.agent == .codex)
        #expect(start.kind == .sessionStart)

        let store = HookSessionStore()
        store.ingest([start])
        #expect(store.entry(for: "C")?.state == .idle)

        let prompt = try #require(
            normalize(#"{"hook_event_name":"UserPromptSubmit","ghostling_agent":"codex","session_id":"C","cwd":"/repo"}"#))
        store.ingest([prompt])
        #expect(store.entry(for: "C")?.state == .running)
    }

    @Test func codexSnakeCasePermissionRequestSetsAttention() throws {
        let event = try #require(
            normalize(#"{"hook_event_name":"permission_request","ghostling_agent":"codex","session_id":"C"}"#))
        #expect(event.kind == .permissionRequest)
        #expect(event.agent == .codex)

        let store = HookSessionStore()
        store.ingest([event])
        #expect(store.entry(for: "C")?.state == .waitingForInput)
    }
}
