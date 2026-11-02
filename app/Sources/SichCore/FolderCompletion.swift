import Foundation

/// The pure half of the palette's inline folder completion — what a typed path means
/// and which listed children it matches. Works the same on a local path and a far-side
/// one: the only thing a host contributes is the child listing itself.
public enum FolderCompletion {

    /// Split typed text into the directory to list and the partial leaf to match.
    /// `~/My` → (`~/`, `My`); `/srv/` → (`/srv/`, ``); `proj` → (``, `proj`) — a bare
    /// word is matched against the home (or login) directory, so typing a project name
    /// straight away works the way a shell's `cd` does.
    public static func split(_ typed: String) -> (parent: String, leaf: String) {
        guard let slash = typed.lastIndex(of: "/") else { return ("", typed) }
        return (String(typed[...slash]), String(typed[typed.index(after: slash)...]))
    }

    /// Where a typed LOCAL path points: `/…` stands, `~` expands, and anything else is
    /// a name under `home` — `MyProjects/` means `~/MyProjects/`, the way `cd` reads it.
    /// Every local read of the field goes through here, so a listing, a commit and the
    /// heading all agree on what a bare name means.
    public static func localDirectory(for typed: String, home: String) -> String {
        if typed.isEmpty || typed == "~" { return home }
        if typed.hasPrefix("/") { return typed }
        if typed.hasPrefix("~/") { return home + typed.dropFirst() }
        return home + "/" + typed
    }

    /// The inverse, for display: a path under `home` reads with `~`.
    public static func abbreviated(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Finder's order — natural, case-insensitive (`d2` before `d10`). Applied ONCE
    /// when a listing is cached: the comparison is the expensive part, and a
    /// keystroke should only ever filter.
    public static func ordered(_ children: [String]) -> [String] {
        children.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// How well a folder `name` answers the typed `leaf`, best first: `0` an exact-case
    /// prefix, `1` a case-insensitive prefix, `2` the leaf found inside the name once
    /// case, spaces, dashes and underscores are ignored (`my projects` → `MyProjects`,
    /// `kanban` → `agentic-coding-kanban`). `nil` when it does not match at all.
    public static func rank(_ name: String, against leaf: String) -> Int? {
        if leaf.isEmpty || name.hasPrefix(leaf) { return 0 }
        if name.lowercased().hasPrefix(leaf.lowercased()) { return 1 }
        let needle = fold(leaf)
        return !needle.isEmpty && fold(name).contains(needle) ? 2 : nil
    }

    private static func fold(_ text: String) -> String {
        text.lowercased().filter { !" -_".contains($0) }
    }

    /// The listed children that complete `leaf`, best matches first and the listing's
    /// order within a tier — one linear pass, see ``rank(_:against:)``. Hidden folders
    /// stay out of the way unless the leaf itself starts with a dot.
    public static func matches(children: [String], leaf: String) -> [String] {
        let wantHidden = leaf.hasPrefix(".")
        var tiers: [[String]] = [[], [], []]
        for name in children {
            if !wantHidden && name.hasPrefix(".") { continue }
            if let tier = rank(name, against: leaf) { tiers[tier].append(name) }
        }
        return tiers.flatMap { $0 }
    }

    /// The longest prefix every candidate shares — what a shell's Tab fills in when
    /// several folders still match.
    public static func commonPrefix(_ names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            while !name.hasPrefix(prefix) { prefix.removeLast() }
            if prefix.isEmpty { break }
        }
        return prefix
    }

    /// One folder's listing: its children, and — when the source looked one level
    /// further — each child's own children, so stepping into one costs nothing.
    public struct Tree: Equatable, Sendable {
        public var children: [String]
        public var grandchildren: [String: [String]]

        public init(children: [String], grandchildren: [String: [String]] = [:]) {
            self.children = children
            self.grandchildren = grandchildren
        }
    }

    /// How many lines the far side may send for one folder. Past this the listing is
    /// truncated, so only the first level is trusted and the second is dropped.
    public static let remoteLineCap = 4000

    /// Parse `find . -mindepth 1 -maxdepth 2 -type d` output from the far side:
    /// `./app` is a child, `./app/src` a grandchild of `app`. Runs on the laptop, so
    /// the remote command stays a fixed string. A listing that hit the cap keeps only
    /// its children — a partial second level would claim folders were empty.
    public static func tree(fromFind output: Data) -> Tree {
        var children: [String] = []
        var grandchildren: [String: [String]] = [:]
        var lines = 0
        for raw in output.split(separator: UInt8(ascii: "\n")) {
            lines += 1
            let line = String(decoding: raw, as: UTF8.self)
            guard line.hasPrefix("./") else { continue }
            let path = line.dropFirst(2)
            if let slash = path.firstIndex(of: "/") {
                grandchildren[String(path[..<slash]), default: []]
                    .append(String(path[path.index(after: slash)...]))
            } else {
                children.append(String(path))
            }
        }
        if lines >= remoteLineCap { return Tree(children: children) }
        for child in children where grandchildren[child] == nil { grandchildren[child] = [] }
        return Tree(children: children, grandchildren: grandchildren)
    }
}
