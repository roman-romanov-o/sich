import Foundation

public enum TaskFolderProgress: Sendable, Equatable {
    case known(completed: Int, total: Int)
    case unknown
}

public struct TaskFolderSummary: Sendable, Equatable, Identifiable {
    public let url: URL
    public let title: String
    public let progress: TaskFolderProgress

    public var id: String { url.standardizedFileURL.path }

    public init(url: URL, title: String, progress: TaskFolderProgress) {
        self.url = url.standardizedFileURL
        self.title = title
        self.progress = progress
    }
}

public struct TaskFolderIndex: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func discover(in projectDirectory: URL) -> [TaskFolderSummary] {
        let tasks = projectDirectory.appendingPathComponent("docs/tasks", isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: tasks,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.compactMap { url in
            guard url.lastPathComponent.hasPrefix("task-"),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            return summarize(url)
        }.sorted { $0.url.lastPathComponent.localizedStandardCompare(
            $1.url.lastPathComponent
        ) == .orderedAscending }
    }

    public func inferredFolder(in projectDirectory: URL) -> URL? {
        let folders = discover(in: projectDirectory)
        if folders.count == 1 { return folders[0].url }
        guard folders.count > 1,
              let pointer = currentTaskPointer(in: projectDirectory)
        else { return nil }

        let matches = folders.filter {
            $0.url.standardizedFileURL.path == pointer.standardizedFileURL.path
                || $0.url.lastPathComponent == pointer.lastPathComponent
        }
        return matches.count == 1 ? matches[0].url : nil
    }

    private func summarize(_ url: URL) -> TaskFolderSummary {
        let readme = url.appendingPathComponent("README.md")
        guard let text = try? String(contentsOf: readme, encoding: .utf8) else {
            return TaskFolderSummary(
                url: url, title: url.lastPathComponent, progress: .unknown
            )
        }
        let title = text.split(separator: "\n").first(where: { $0.hasPrefix("# ") })
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            ?? url.lastPathComponent
        let markers = text.split(separator: "\n").filter {
            $0.contains("- [x]") || $0.contains("- [X]") || $0.contains("- [ ]")
        }
        if !markers.isEmpty {
            let completed = markers.filter {
                $0.contains("- [x]") || $0.contains("- [X]")
            }.count
            return TaskFolderSummary(
                url: url,
                title: title,
                progress: .known(completed: completed, total: markers.count)
            )
        }

        guard let tableProgress = planningTableProgress(in: text) else {
            return TaskFolderSummary(url: url, title: title, progress: .unknown)
        }
        return TaskFolderSummary(
            url: url, title: title, progress: tableProgress
        )
    }

    private func planningTableProgress(in text: String) -> TaskFolderProgress? {
        let lines = text.components(separatedBy: .newlines)
        guard let heading = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces)
                .localizedCaseInsensitiveContains("planning progress")
        }) else { return nil }

        let section = lines.dropFirst(heading + 1).prefix {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
        let statuses = section.compactMap { line -> String? in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4,
                  !cells[1].localizedCaseInsensitiveContains("step"),
                  !cells[1].allSatisfy({ $0 == "-" || $0 == ":" })
            else { return nil }
            return cells[2]
        }
        guard !statuses.isEmpty else { return nil }
        let completed = statuses.filter {
            let status = $0.lowercased()
            return status.hasPrefix("done")
                || status.hasPrefix("complete")
                || status.contains("✅")
        }.count
        return .known(completed: completed, total: statuses.count)
    }

    private func currentTaskPointer(in projectDirectory: URL) -> URL? {
        let file = projectDirectory.appendingPathComponent(".sahaidachny/current-task")
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !path.isEmpty, !path.contains("..") else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        if path.hasPrefix("docs/") {
            return projectDirectory.appendingPathComponent(path, isDirectory: true)
        }
        return projectDirectory.appendingPathComponent("docs/tasks", isDirectory: true)
            .appendingPathComponent(path, isDirectory: true)
    }
}
