import Foundation

/// Parses the "Models & Quota" panel of Google's Antigravity CLI (`agy`) — the
/// plain-text screen a libghostty ``Terminal`` produces after the hidden probe
/// types `/usage`. Antigravity meters per-model buckets, each a rolling window
/// with its own percentage and reset; the gauge tracks the TIGHTEST bucket (the
/// one that will stop the user first), so a bucket the CLI shows as `Disabled`
/// (no bar) is skipped.
///
/// The layout is read defensively — one bucket per line, a `NN%` figure whose
/// meaning is taken from the words next to it (`used` vs `left`/`remaining`), an
/// optional `resets in 2h 13m` / `resets at …` tail — because the panel has only
/// been seen described, not captured (the probe needs a signed-in `agy`). Any
/// drift degrades to `unknown`, never a fake zero.
public enum AntigravityUsagePanel {
    public struct Bucket: Equatable, Sendable {
        public let label: String
        public let usedPercent: Double
        public let resetsAt: Date?
        public let refillKind: QuotaRefillKind

        public init(label: String, usedPercent: Double, resetsAt: Date?, refillKind: QuotaRefillKind = .weekly) {
            self.label = label
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.refillKind = refillKind
        }
    }

    public struct Reading: Equatable, Sendable {
        public let buckets: [Bucket]

        public init(buckets: [Bucket]) {
            self.buckets = buckets
        }

        public var tightest: Bucket? {
            buckets.max { $0.usedPercent < $1.usedPercent }
        }
    }

    public static func parse(screen: String, now: Date = Date()) -> Reading? {
        guard screen.localizedCaseInsensitiveContains("quota") else { return nil }

        var buckets: [Bucket] = []
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var currentGroupLabel: String?
        var currentLimitKind: QuotaRefillKind?
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty || trimmed.allSatisfy({ "─╭╮╰╯│┃|".contains($0) }) {
                i += 1
                continue
            }

            if let singleLineBucket = parseSingleLineBucket(line: line, now: now) {
                buckets.append(singleLineBucket)
                currentGroupLabel = nil
                currentLimitKind = nil
                i += 1
                continue
            }

            if trimmed.localizedCaseInsensitiveContains("disabled") {
                currentGroupLabel = nil
                currentLimitKind = nil
                i += 1
                continue
            }

            if isGroupHeader(trimmed) {
                currentGroupLabel = trimmed
                currentLimitKind = nil
                i += 1
                continue
            }

            if trimmed.localizedCaseInsensitiveContains("limit remaining") {
                currentLimitKind = parseLimitKind(trimmed)
                i += 1
                continue
            }

            if let group = currentGroupLabel,
               let percentMatch = line.firstMatch(of: #/(\d+(?:\.\d+)?)\s*%/#),
               let pct = Double(percentMatch.1) {

                var reset = resetDate(in: line, now: now)
                var isRemaining = line.localizedCaseInsensitiveContains("remaining") || line.localizedCaseInsensitiveContains("left")

                if i + 1 < lines.count {
                    let nextLine = lines[i + 1]
                    if reset == nil {
                        reset = resetDate(in: nextLine, now: now)
                    }
                    if !isRemaining && (nextLine.localizedCaseInsensitiveContains("remaining") ||
                                       nextLine.localizedCaseInsensitiveContains("left") ||
                                       nextLine.localizedCaseInsensitiveContains("available")) {
                        isRemaining = true
                    }
                }

                let used = isRemaining || trimmed.contains("[") ? max(0, min(100, 100.0 - pct)) : max(0, min(100, pct))
                let refill = currentLimitKind ?? inferRefillKind(line: line, reset: reset, now: now)
                buckets.append(Bucket(label: formatGroupLabel(group), usedPercent: used, resetsAt: reset, refillKind: refill))
                currentGroupLabel = nil
                currentLimitKind = nil
                i += 1
                continue
            }

            i += 1
        }

        return buckets.isEmpty ? nil : Reading(buckets: buckets)
    }

    public static func source(from reading: Reading) -> QuotaSourceInput {
        let tight = reading.tightest
        let remaining = tight.map { max(0.0, min(1.0, 1.0 - $0.usedPercent / 100.0)) } ?? 1.0
        return QuotaSourceInput(
            provider: "antigravity", pool: "antigravity",
            reading: QuotaSourceReading(
                available: true,
                inferred: false,
                remainingFraction: remaining,
                reset: tight?.resetsAt,
                refillKind: tight?.refillKind ?? .weekly,
                state: remaining <= 0.0 ? .exhausted : .active
            )
        )
    }

    public static func displaySources(from reading: Reading) -> [QuotaSourceInput] {
        var sources: [QuotaSourceInput] = []
        let rolling = reading.buckets.first { $0.refillKind == .rollingWindow }
        let weekly = reading.buckets.first { $0.refillKind == .weekly } ?? reading.tightest

        if let rolling {
            let remaining = max(0.0, min(1.0, 1.0 - rolling.usedPercent / 100.0))
            sources.append(QuotaSourceInput(
                provider: "antigravity", pool: "antigravity_5h",
                reading: QuotaSourceReading(
                    available: true,
                    inferred: false,
                    remainingFraction: remaining,
                    reset: rolling.resetsAt,
                    refillKind: .rollingWindow,
                    state: remaining <= 0.0 ? .exhausted : .active
                )
            ))
        }

        if let weekly {
            let remaining = max(0.0, min(1.0, 1.0 - weekly.usedPercent / 100.0))
            sources.append(QuotaSourceInput(
                provider: "antigravity", pool: "antigravity_weekly",
                reading: QuotaSourceReading(
                    available: true,
                    inferred: false,
                    remainingFraction: remaining,
                    reset: weekly.resetsAt,
                    refillKind: weekly.refillKind,
                    state: remaining <= 0.0 ? .exhausted : .active
                )
            ))
        }

        return sources
    }

    private static func parseSingleLineBucket(line: String, now: Date) -> Bucket? {
        guard !line.localizedCaseInsensitiveContains("disabled"),
              let match = line.firstMatch(of: #/(\d+(?:\.\d+)?)\s*%/#),
              let percent = Double(match.1) else { return nil }

        let prefix = String(line[..<match.range.lowerBound])
            .replacing(#/[█░▓▒▏▎▍▌▋▊▉│┃|\[\]]+/#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !prefix.isEmpty,
              !prefix.localizedCaseInsensitiveContains("limit remaining"),
              !prefix.localizedCaseInsensitiveContains("refreshes in"),
              !prefix.localizedCaseInsensitiveContains("models within") else {
            return nil
        }

        let tail = String(line[match.range.upperBound...]).lowercased()
        let isRemaining = tail.contains("left") || tail.contains("remaining") || prefix.lowercased().contains("remaining")
        let used = isRemaining ? 100 - percent : percent
        let reset = resetDate(in: line, now: now)
        let refill = inferRefillKind(line: line, reset: reset, now: now)

        return Bucket(label: prefix, usedPercent: max(0, min(100, used)),
                      resetsAt: reset, refillKind: refill)
    }

    private static func parseLimitKind(_ line: String) -> QuotaRefillKind {
        let lower = line.lowercased()
        if lower.contains("monthly") { return .monthlyHardStop }
        if lower.contains("daily") || lower.contains("5-hour") || lower.contains("5h") || lower.contains("rolling") || lower.contains("session") {
            return .rollingWindow
        }
        return .weekly
    }

    private static func inferRefillKind(line: String, reset: Date?, now: Date) -> QuotaRefillKind {
        let lower = line.lowercased()
        if lower.contains("monthly") { return .monthlyHardStop }
        if lower.contains("daily") || lower.contains("5h") || lower.contains("session") { return .rollingWindow }
        if lower.contains("weekly") { return .weekly }
        if let reset {
            let duration = reset.timeIntervalSince(now)
            if duration > 86_400 { return .weekly }
            if duration > 0 { return .rollingWindow }
        }
        return .weekly
    }

    private static func isGroupHeader(_ line: String) -> Bool {
        guard line.count >= 3,
              !line.contains("%"), !line.contains("["), !line.contains("]"),
              !line.contains("─"), !line.contains("│"), !line.contains("┃"),
              !line.contains("▄"), !line.contains("▀"), !line.contains(">"),
              !line.contains("@") else { return false }

        let lower = line.lowercased()
        if lower.hasPrefix("account:") ||
           lower.contains("models & quota") ||
           lower.hasPrefix("models within") ||
           lower.contains("limit remaining") ||
           lower.contains("refreshes in") ||
           lower.contains("resets in") ||
           lower.contains("quota available") ||
           lower.contains("within each group") ||
           lower.contains("scroll") ||
           lower.contains("esc ") ||
           lower.contains("shortcuts") ||
           lower.contains("antigravity cli") {
            return false
        }
        return true
    }

    private static func formatGroupLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == trimmed.uppercased() && trimmed != trimmed.lowercased() {
            return trimmed.capitalized
        }
        return trimmed
    }

    private static func resetDate(in line: String, now: Date) -> Date? {
        guard let match = line.firstMatch(of: #/(?i)(?:resets?|refreshes?)\s+in\s+((?:\d+\s*[dhms]\s*)+)/#) else { return nil }
        var seconds: TimeInterval = 0
        for part in String(match.1).matches(of: #/(\d+)\s*([dhms])/#) {
            let value = Double(part.1) ?? 0
            switch part.2 {
            case "d": seconds += value * 86_400
            case "h": seconds += value * 3_600
            case "m": seconds += value * 60
            default: seconds += value
            }
        }
        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }
}

/// The Antigravity probe: a hidden `agy`, its folder-trust dialog accepted, its
/// `/usage` page read by ``AntigravityUsagePanel``.
public enum AntigravityUsageProbe {
    public static let spec = TUIUsageProbeSpec<AntigravityUsagePanel.Reading>(
        launch: "agy",
        readyMarkers: ["? for shortcuts"],
        trustPrompt: "trust this folder",
        parse: { AntigravityUsagePanel.parse(screen: $0) }
    )

    public static let shared = TUIUsageProbe(spec: spec)

    public static func scrape(deadline: TimeInterval = 75) -> AntigravityUsagePanel.Reading? {
        TUIUsageProbe.scrape(spec: spec, deadline: deadline)
    }
}
