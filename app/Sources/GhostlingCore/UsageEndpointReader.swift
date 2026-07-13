import Foundation
import Security

/// The interactive-pool quota read from Claude's OWN authenticated usage endpoint
/// (`GET /api/oauth/usage`) — the ACTUAL utilization% Anthropic enforces, with the
/// real reset times, instead of the JSONL token-count estimate against a guessed
/// cap (which over-counted ~2x because cache-read tokens dominate the sum). This is
/// the same call `claude` makes for its `/usage` view; we read the same number it
/// shows. Marked `inferred:false` so the gauge renders it `measured`, not `estimated`.
///
/// Watcher-not-spawner intact: this READS the user's own usage; it never spawns
/// `claude -p`, binds no port, and starts no process. On any failure (no token,
/// offline, token expired, keychain access denied) `fetch()` returns nil and the
/// caller falls back to the local estimate — honest degradation, never a fake zero.
public enum UsageEndpointReader {

    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// One of the two constraints the gauge cares about, decoded from the payload.
    struct Constraint: Equatable {
        let utilization: Double   // percent used, 0…100
        let resetsAt: Date?
    }

    // MARK: - Pure decode + projection (unit-tested)

    /// Build the interactive `QuotaSourceInput` from a raw endpoint payload. The
    /// binding constraint is whichever has LESS remaining (higher utilization) — its
    /// reset and refill kind drive the gauge, exactly as the local window math's
    /// `min(window, weekly)` did. Returns nil if the payload can't be parsed, so the
    /// caller falls back to the local estimate.
    public static func interactiveSource(from data: Data) -> QuotaSourceInput? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let window = constraint(root["five_hour"]),
              let weekly = constraint(root["seven_day"]) else { return nil }
        let windowBinds = window.utilization >= weekly.utilization
        let binding = windowBinds ? window : weekly
        let remaining = max(0.0, min(1.0, 1.0 - binding.utilization / 100.0))
        return QuotaSourceInput(
            provider: "anthropic", pool: "interactive",
            reading: QuotaSourceReading(
                available: true,
                inferred: false,               // real measurement → gauge shows "measured"
                remainingFraction: remaining,
                reset: binding.resetsAt,
                refillKind: windowBinds ? .rollingWindow : .weekly,
                state: remaining <= 0.0 ? .exhausted : .active
            )
        )
    }

    public static func interactiveDisplaySources(from data: Data) -> [QuotaSourceInput]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let window = constraint(root["five_hour"]),
              let weekly = constraint(root["seven_day"]) else { return nil }
        return [
            splitSource(pool: "interactive_5h", constraint: window, refill: .rollingWindow),
            splitSource(pool: "interactive_weekly", constraint: weekly, refill: .weekly),
        ]
    }

    private static func splitSource(
        pool: String, constraint: Constraint, refill: QuotaRefillKind
    ) -> QuotaSourceInput {
        let remaining = max(0.0, min(1.0, 1.0 - constraint.utilization / 100.0))
        return QuotaSourceInput(
            provider: "anthropic", pool: pool,
            reading: QuotaSourceReading(
                available: true,
                inferred: false,
                remainingFraction: remaining,
                reset: constraint.resetsAt,
                refillKind: refill,
                state: remaining <= 0.0 ? .exhausted : .active
            )
        )
    }

    private static func constraint(_ raw: Any?) -> Constraint? {
        guard let obj = raw as? [String: Any],
              let util = (obj["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let reset = (obj["resets_at"] as? String).flatMap(parseReset)
        return Constraint(utilization: util, resetsAt: reset)
    }

    private static func parseReset(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    // MARK: - I/O (keychain + network — not unit-tested)

    /// Fetch the live payload, or nil on any failure. Caller falls back to the local
    /// estimate, so every error path degrades quietly.
    public static func fetch() async -> Data? {
        guard let token = keychainToken() else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// The OAuth access token from the `Claude Code-credentials` generic-password
    /// keychain item (a JSON blob; the token lives under `claudeAiOauth.accessToken`).
    /// ponytail: cross-app keychain ACL may deny our binary or prompt once — on
    /// denial this returns nil and we fall back to the estimate. Upgrade path if that
    /// bites: add our signed binary to the item's ACL, or `security find-generic-password`.
    public static func keychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let oauth = (blob["claudeAiOauth"] as? [String: Any]) ?? blob
        return oauth["accessToken"] as? String
    }
}
