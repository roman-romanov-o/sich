import Foundation
import Yams

/// Writes review approvals back into a saha/v2 `progress.yaml` — the file the saha
/// loop already treats as the single tracking surface. Edits are surgical line
/// patches on the raw text: the Codable structs drop keys they don't model
/// (`created`, `mode`, `gaps`, `iterations`) and lose comments/formatting, so a
/// decode→re-encode round trip would corrupt real task files.
///
/// Writer discipline: during EXECUTION the saha manager agent is the only writer
/// of progress.yaml. Every write here is gated on the task still being in
/// `status: planning`; any other status — or a legacy/malformed file — refuses.
public enum PlanningProgressWriteback {
    /// Flip the story matching `reviewKey` (its `view:` id, `US-XXX` id, or the
    /// derived `us-xxx-flow`) from `draft` to `ready`. Returns true iff the file
    /// changed on disk.
    @discardableResult
    public static func approveStory(taskFolder: URL, reviewKey: String) -> Bool {
        patch(taskFolder: taskFolder) { text in
            guard let storyID = storyID(matching: reviewKey, in: text) else { return nil }
            return settingStoryStatus(text, storyID: storyID, from: ["draft"], to: "ready")
        }
    }

    /// Mark a planning step `done` (called once its artifacts are all approved).
    /// Only `pending`/`in_progress` are upgraded; `done`/`skipped` stay put.
    @discardableResult
    public static func markStepDone(taskFolder: URL, step: PlanningStep) -> Bool {
        patch(taskFolder: taskFolder) { text in
            settingStepStatus(text, wireName: step.wireName,
                              from: ["pending", "in_progress"], to: "done")
        }
    }

    // MARK: - File plumbing

    private static func patch(taskFolder: URL, _ transform: (String) -> String?) -> Bool {
        let file = taskFolder.appendingPathComponent("progress.yaml")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              isWritable(text),
              let patched = transform(text), patched != text
        else { return false }
        return (try? patched.write(to: file, atomically: true, encoding: .utf8)) != nil
    }

    /// v2 marker present AND the top-level task status is still `planning`.
    static func isWritable(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        let hasMarker = lines.contains {
            $0.trimmingCharacters(in: .whitespaces) == PlanningProgressReader.formatMarker
        }
        let status = lines.first { indent(of: $0) == 0 && $0.hasPrefix("status:") }
            .map { $0.dropFirst("status:".count).trimmingCharacters(in: .whitespaces) }
        return hasMarker && status == "planning"
    }

    // MARK: - Story lookup (decode is fine for READING)

    static func storyID(matching reviewKey: String, in text: String) -> String? {
        guard let progress = try? YAMLDecoder().decode(PlanningProgress.self, from: text)
        else { return nil }
        return (progress.stories ?? []).first { story in
            story.view == reviewKey
                || story.id == reviewKey
                || story.id.map { "\($0.lowercased())-flow" } == reviewKey
        }?.id ?? nil
    }

    // MARK: - Text surgery

    static func settingStoryStatus(
        _ text: String, storyID: String, from allowed: [String], to newValue: String
    ) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let range = storyItemRange(lines: lines, storyID: storyID) else { return nil }
        let fieldIndent = indent(of: lines[range.lowerBound]) + 2
        for i in range {
            let line = lines[i]
            // Inline flow item (`- {id: US-002, …, status: draft}`).
            if i == range.lowerBound, line.contains("{") {
                guard let patched = replacingStatusValue(in: line, from: allowed, to: newValue)
                else { return nil }
                lines[i] = patched
                return lines.joined(separator: "\n")
            }
            // Block item: the story's own status sits at exactly the field indent —
            // acceptance_criteria statuses are deeper and never match.
            if indent(of: line) == fieldIndent,
               line.trimmingCharacters(in: .whitespaces).hasPrefix("status:") {
                guard let patched = replacingStatusValue(in: line, from: allowed, to: newValue)
                else { return nil }
                lines[i] = patched
                return lines.joined(separator: "\n")
            }
        }
        return nil
    }

    static func settingStepStatus(
        _ text: String, wireName: String, from allowed: [String], to newValue: String
    ) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            indent(of: $0) == 0 && $0.trimmingCharacters(in: .whitespaces) == "planning:"
        }) else { return nil }
        let end = blockEnd(lines: lines, after: start)
        for i in (start + 1)..<end {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(wireName):") else { continue }
            if lines[i].contains("{") {
                guard let patched = replacingStatusValue(in: lines[i], from: allowed, to: newValue)
                else { return nil }
                lines[i] = patched
                return lines.joined(separator: "\n")
            }
            let keyIndent = indent(of: lines[i])
            for j in (i + 1)..<end {
                let inner = lines[j].trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty, indent(of: lines[j]) <= keyIndent { break }
                if inner.hasPrefix("status:") {
                    guard let patched = replacingStatusValue(in: lines[j], from: allowed,
                                                            to: newValue)
                    else { return nil }
                    lines[j] = patched
                    return lines.joined(separator: "\n")
                }
            }
            return nil
        }
        return nil
    }

    // MARK: - Scanning helpers

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// First index at-or-after `start + 1` holding a new top-level key (= end of block).
    private static func blockEnd(lines: [String], after start: Int) -> Int {
        for i in (start + 1)..<lines.count {
            let line = lines[i]
            if !line.isEmpty, indent(of: line) == 0, !line.hasPrefix("#") { return i }
        }
        return lines.count
    }

    /// The line range of the `stories:` list item whose `id:` equals `storyID`.
    static func storyItemRange(lines: [String], storyID: String) -> Range<Int>? {
        guard let storiesIdx = lines.firstIndex(where: {
            indent(of: $0) == 0 && $0.trimmingCharacters(in: .whitespaces) == "stories:"
        }) else { return nil }
        let end = blockEnd(lines: lines, after: storiesIdx)
        // Story items are the dashes at the SHALLOWEST indent inside the block;
        // deeper dashes (acceptance_criteria, edge_cases) are nested content.
        var itemStarts: [Int] = []
        var minDash = Int.max
        for i in (storiesIdx + 1)..<end {
            let dashIndent = indent(of: lines[i])
            guard lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("- ") else { continue }
            if dashIndent < minDash {
                minDash = dashIndent
                itemStarts = [i]
            } else if dashIndent == minDash {
                itemStarts.append(i)
            }
        }
        for (n, start) in itemStarts.enumerated() {
            let itemEnd = n + 1 < itemStarts.count ? itemStarts[n + 1] : end
            if itemHasID(lines: lines, range: start..<itemEnd, dashIndent: minDash,
                         storyID: storyID) {
                return start..<itemEnd
            }
        }
        return nil
    }

    private static func itemHasID(
        lines: [String], range: Range<Int>, dashIndent: Int, storyID: String
    ) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: storyID)
        for i in range {
            let line = lines[i]
            if i == range.lowerBound {
                if line.contains("{") {
                    return line.range(of: "\\bid:\\s*\(escaped)\\s*[,}]",
                                      options: .regularExpression) != nil
                }
                let firstField = String(line.dropFirst(dashIndent + 2))
                if firstField == "id: \(storyID)" { return true }
                continue
            }
            guard indent(of: line) == dashIndent + 2 else { continue }
            if line.trimmingCharacters(in: .whitespaces) == "id: \(storyID)" { return true }
        }
        return false
    }

    /// Rewrite the FIRST `status:` bare-scalar on the line iff its current value is
    /// in `allowed`. Anything unexpected (quoted, missing, wrong state) → nil, no write.
    static func replacingStatusValue(
        in line: String, from allowed: [String], to newValue: String
    ) -> String? {
        let pattern = "\\bstatus:(\\s*)([A-Za-z_]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line,
                                           range: NSRange(line.startIndex..., in: line)),
              let valueRange = Range(match.range(at: 2), in: line),
              allowed.contains(String(line[valueRange]))
        else { return nil }
        return line.replacingCharacters(in: valueRange, with: newValue)
    }
}
