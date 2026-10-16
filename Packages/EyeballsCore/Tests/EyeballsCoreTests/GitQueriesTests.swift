import EyeballsCore
import Foundation
import Testing

struct GitQueriesTests {
    @Test func resolvesCommitsAndTrees() async throws {
        let fixture = try GitFixture()
        let commit = try fixture.commit("one")
        let repository = try await fixture.repository()

        #expect(try await repository.resolveCommit("main") == commit)
        #expect(try await repository.resolveCommit("refs/heads/main") == commit)
        #expect(try await repository.resolveCommit("no-such-branch") == nil)
        #expect(try await repository.tree(of: commit) == fixture.sha("main^{tree}"))
    }

    @Test func answersAncestryQuestions() async throws {
        let fixture = try GitFixture()
        let root = try fixture.commit("root")
        try fixture.git(["checkout", "-q", "-b", "side"])
        let side = try fixture.commit("side")
        try fixture.git(["checkout", "-q", "main"])
        let main = try fixture.commit("main")
        let repository = try await fixture.repository()

        #expect(try await repository.mergeBase(side.hex, main.hex) == root)
        #expect(try await repository.isAncestor(root.hex, of: side.hex))
        #expect(try await repository.isAncestor(side.hex, of: side.hex))
        #expect(try await !repository.isAncestor(main.hex, of: side.hex))
    }

    @Test func findsAForkPointFromTheUpstreamReflog() async throws {
        let fixture = try GitFixture()
        try fixture.commit("root")
        let oldTip = try fixture.commit("old tip")
        try fixture.git(["checkout", "-q", "-b", "topic"])
        let topic = try fixture.commit("topic")
        try fixture.git(["checkout", "-q", "main"])
        try fixture.git(["commit", "-q", "--amend", "--allow-empty", "-m", "rewritten tip"])
        let repository = try await fixture.repository()

        #expect(try await repository.forkPoint(upstream: "refs/heads/main", of: topic.hex) == oldTip)
        #expect(try await !repository.isAncestor("main", of: topic.hex))
    }

    @Test func returnsNoForkPointWhenThereIsNone() async throws {
        let fixture = try GitFixture()
        try fixture.commit("root")
        let orphan = try fixture.commitTree([], parent: nil, message: "unrelated")
        let repository = try await fixture.repository()
        #expect(try await repository.forkPoint(upstream: "refs/heads/main", of: orphan.hex) == nil)
        #expect(try await repository.mergeBase("main", orphan.hex) == nil)
    }

    @Test func listsReferencesUnderPrefixes() async throws {
        let fixture = try GitFixture()
        let commit = try fixture.commit("one")
        try fixture.git(["branch", "feature/a"])
        try fixture.git(["update-ref", "refs/remotes/origin/main", commit.hex])
        try fixture.git(["tag", "v1"])
        let repository = try await fixture.repository()

        let references = try await repository.references(under: ["refs/heads/", "refs/remotes/origin/"])
        #expect(references.map(\.name).sorted() == ["refs/heads/feature/a", "refs/heads/main", "refs/remotes/origin/main"])
        #expect(references.allSatisfy { $0.target == commit })
    }

    @Test func readsTheCurrentBranchAndSymbolicRefs() async throws {
        let fixture = try GitFixture()
        let commit = try fixture.commit("one")
        try fixture.git(["update-ref", "refs/remotes/origin/develop", commit.hex])
        try fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"])
        let repository = try await fixture.repository()

        #expect(try await repository.currentBranch() == "main")
        #expect(try await repository.symbolicTarget(of: "refs/remotes/origin/HEAD") == "refs/remotes/origin/develop")
        try fixture.git(["checkout", "-q", "--detach"])
        #expect(try await repository.currentBranch() == nil)
    }

    @Test func listsALayersCommitsNewestFirst() async throws {
        let fixture = try GitFixture()
        let base = try fixture.commit("base")
        let first = try fixture.commit("Add the model")
        let second = try fixture.commit("Use the model: with \"quotes\" and ünïcode")
        let repository = try await fixture.repository()

        let commits = try await repository.commits(from: base, to: second)
        #expect(commits.map(\.sha) == [second, first])
        #expect(commits.map(\.subject) == ["Use the model: with \"quotes\" and ünïcode", "Add the model"])
        #expect(commits.allSatisfy { $0.author == "Eyeballs" })
        #expect(commits[0].date > commits[1].date)
        #expect(try await repository.commits(from: second, to: second).isEmpty)
    }

    @Test func findsBlobsByPathIncludingPathsThatAreNotUTF8() async throws {
        let fixture = try GitFixture()
        let plain = try fixture.blob(Data("plain\n".utf8))
        let latin1 = try fixture.blob(Data("latin-1 name\n".utf8))
        let nonUTF8: [UInt8] = Array("dir/caf".utf8) + [0xE9] + Array(".txt".utf8)
        let commit = try fixture.commitTree([
            ("100644", plain, Array("dir/plain file.txt".utf8)),
            ("100644", latin1, nonUTF8),
        ], parent: nil, message: "paths")
        let repository = try await fixture.repository()

        #expect(try await repository.blobID(in: commit, at: GitPath("dir/plain file.txt")) == plain)
        #expect(try await repository.blobID(in: commit, at: GitPath(bytes: nonUTF8)) == latin1)
        #expect(try await repository.blobID(in: commit, at: GitPath("dir/missing.txt")) == nil)
        #expect(try await repository.blobID(in: commit, at: GitPath("dir")) == nil)
    }
}
