import Foundation
import Testing

@testable import SichCore

/// The pure half of the palette's inline folder completion — the same rules for a
/// local path and a far-side one.
struct FolderCompletionTests {

    @Test("a typed path splits into the folder to list and the leaf to match")
    func splitsParentAndLeaf() {
        #expect(FolderCompletion.split("~/My").parent == "~/")
        #expect(FolderCompletion.split("~/My").leaf == "My")
        #expect(FolderCompletion.split("/srv/").parent == "/srv/")
        #expect(FolderCompletion.split("/srv/").leaf == "")
        #expect(FolderCompletion.split("proj").parent == "")
        #expect(FolderCompletion.split("proj").leaf == "proj")
    }

    @Test("a listing is ordered once, Finder-style; matches keep that order, exact case first")
    func ranksMatches() {
        let children = FolderCompletion.ordered(["beta", "d10", "Alpha", "alps", ".git", "alpine", "d2"])
        #expect(children == [".git", "Alpha", "alpine", "alps", "beta", "d2", "d10"])
        #expect(FolderCompletion.matches(children: children, leaf: "al")
                == ["alpine", "alps", "Alpha"])
        #expect(FolderCompletion.matches(children: children, leaf: "")
                == ["Alpha", "alpine", "alps", "beta", "d2", "d10"])
        #expect(FolderCompletion.matches(children: children, leaf: ".") == [".git"])
    }

    @Test("a loose match ignores case, spaces, dashes and underscores, and ranks after a prefix")
    func looseMatches() {
        let children = ["Agentic-Data-Science", "MyProjects", "agentic-coding-kanban", "my_notes", "projects"]
        #expect(FolderCompletion.matches(children: children, leaf: "my projects") == ["MyProjects"])
        #expect(FolderCompletion.matches(children: children, leaf: "kanban") == ["agentic-coding-kanban"])
        #expect(FolderCompletion.matches(children: children, leaf: "projects") == ["projects", "MyProjects"],
                "the prefix match comes before the one found inside a name")
        #expect(FolderCompletion.rank("MyProjects", against: "My") == 0)
        #expect(FolderCompletion.rank("MyProjects", against: "my") == 1)
        #expect(FolderCompletion.rank("MyProjects", against: "proj") == 2)
        #expect(FolderCompletion.rank("MyProjects", against: "zzz") == nil)
        #expect(FolderCompletion.rank("MyProjects", against: " - ") == nil, "nothing left to match on")
    }

    @Test("a bare local name lives under home; ~ expands and an absolute path stands")
    func localDirectory() {
        let home = "/Users/me"
        #expect(FolderCompletion.localDirectory(for: "", home: home) == home)
        #expect(FolderCompletion.localDirectory(for: "~", home: home) == home)
        #expect(FolderCompletion.localDirectory(for: "~/", home: home) == "/Users/me/")
        #expect(FolderCompletion.localDirectory(for: "~/My", home: home) == "/Users/me/My")
        #expect(FolderCompletion.localDirectory(for: "MyProjects/", home: home) == "/Users/me/MyProjects/")
        #expect(FolderCompletion.localDirectory(for: "/srv/app", home: home) == "/srv/app")
        #expect(FolderCompletion.abbreviated("/Users/me/MyProjects/", home: home) == "~/MyProjects/")
        #expect(FolderCompletion.abbreviated("/Users/me", home: home) == "~")
        #expect(FolderCompletion.abbreviated("/Users/meow/x", home: home) == "/Users/meow/x")
    }

    @Test("the shared prefix is what ⇥ fills in while several folders still match")
    func commonPrefix() {
        #expect(FolderCompletion.commonPrefix(["alpine", "alps", "alpha"]) == "alp")
        #expect(FolderCompletion.commonPrefix(["one"]) == "one")
        #expect(FolderCompletion.commonPrefix([]) == "")
        #expect(FolderCompletion.commonPrefix(["a", "b"]) == "")
    }

    @Test("a far-side find listing yields children and each child's own children")
    func parsesTwoLevelListing() {
        let output = Data("./app\n./app/src\n./app/tests\n./www\n./.git\n./.git/hooks\n".utf8)
        let tree = FolderCompletion.tree(fromFind: output)
        #expect(tree.children == ["app", "www", ".git"])
        #expect(tree.grandchildren["app"] == ["src", "tests"])
        #expect(tree.grandchildren["www"] == [], "a child with no folders is known empty, not unknown")
        #expect(tree.grandchildren[".git"] == ["hooks"])
    }

    @Test("a listing that hit the line cap keeps its children and drops the untrusted second level")
    func cappedListingDropsGrandchildren() {
        var lines = ["./a", "./b"]
        lines += (0..<FolderCompletion.remoteLineCap).map { "./a/\($0)" }
        let tree = FolderCompletion.tree(fromFind: Data(lines.joined(separator: "\n").utf8))
        #expect(tree.children == ["a", "b"])
        #expect(tree.grandchildren.isEmpty)
    }

    @Test("the remote listing takes its folder on stdin — never as a shell word")
    func listingArgvInterpolatesNothing() throws {
        let spec = RemoteTmuxSpec(host: "box", user: "me", sessionName: "sich")
        let argv = try RemoteTmuxCommand.listFoldersArgv(for: spec)
        #expect(argv.first == "/usr/bin/ssh")
        #expect(argv.contains("me@box"))
        let command = try #require(argv.last)
        #expect(command.hasPrefix("IFS= read -r d;"), "the path arrives on stdin")
        #expect(command.contains("exit 3"), "an unenterable folder is distinct from an ssh failure")
        #expect(command.contains("-maxdepth 2"), "two levels per handshake")
        #expect(command.contains("head -n \(FolderCompletion.remoteLineCap)"), "…bounded")
        #expect(!argv.contains("-t"), "no PTY on a data channel")
    }

    @Test("a Windows host has no POSIX listing channel")
    func windowsHostHasNoListing() {
        let spec = RemoteTmuxSpec(host: "winbox", sessionName: "sich", hostKind: .windowsPsmux)
        #expect(throws: RemoteTmuxCommand.Invalid.posixChannelOnWindowsHost) {
            try RemoteTmuxCommand.listFoldersArgv(for: spec)
        }
    }
}
