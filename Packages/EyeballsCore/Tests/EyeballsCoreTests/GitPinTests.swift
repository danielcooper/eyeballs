import EyeballsCore
import Foundation
import Testing

struct GitPinTests {
    @Test func pinsListsAndReleasesCommits() async throws {
        let fixture = try GitFixture()
        let first = try fixture.commit("one")
        let second = try fixture.commit("two")
        let pins = try PinStore(repository: try await fixture.repository(), installID: "install-1")

        try await pins.pin([first, second, first])
        #expect(try await pins.pinnedCommits() == [first, second])
        #expect(try fixture.git(["rev-parse", "refs/eyeballs/install-1/\(first.hex)"]) == first.hex)

        try await pins.pin([first])
        #expect(try await pins.pinnedCommits() == [first, second])

        try await pins.release([first, try #require(ObjectID(String(repeating: "c", count: 40)))])
        #expect(try await pins.pinnedCommits() == [second])
    }

    @Test func keepsInstallsApart() async throws {
        let fixture = try GitFixture()
        let commit = try fixture.commit("one")
        let repository = try await fixture.repository()
        let release = try PinStore(repository: repository, installID: "release")
        let debug = try PinStore(repository: repository, installID: "debug")

        try await debug.pin([commit])
        #expect(try await release.pinnedCommits().isEmpty)
        #expect(try await debug.pinnedCommits() == [commit])
    }

    @Test func pinnedCommitsSurviveARebaseAndGarbageCollection() async throws {
        let fixture = try GitFixture()
        try fixture.commit("base")
        try fixture.git(["checkout", "-q", "-b", "topic"])
        try fixture.write("a.txt", "reviewed\n")
        let reviewed = try fixture.commit("reviewed")
        let pins = try PinStore(repository: try await fixture.repository(), installID: "i1")
        try await pins.pin([reviewed])
        try fixture.write("a.txt", "not reviewed\n")
        let unpinned = try fixture.commit("not reviewed")

        try fixture.git(["reset", "-q", "--hard", "main"])
        try fixture.git(["reflog", "expire", "--expire=now", "--all"])
        try fixture.git(["gc", "-q", "--prune=now"])
        #expect(try fixture.git(["cat-file", "-t", reviewed.hex]) == "commit")
        #expect(throws: FixtureError.self, "The fixture should prove gc removes commits nothing pins") {
            try fixture.git(["cat-file", "-t", unpinned.hex])
        }
    }

    @Test func refusesToPinAMissingCommitAndPinsNothing() async throws {
        let fixture = try GitFixture()
        let commit = try fixture.commit("one")
        let missing = try #require(ObjectID(String(repeating: "d", count: 40)))
        let pins = try PinStore(repository: try await fixture.repository(), installID: "i1")

        await #expect(throws: GitError.self) { try await pins.pin([commit, missing]) }
        #expect(try await pins.pinnedCommits().isEmpty)
    }

    @Test func neverRunsTheRepositorysReferenceTransactionHook() async throws {
        let fixture = try GitFixture()
        let commit = try fixture.commit("one")
        let marker = fixture.root.appendingPathComponent("hook-ran")
        let hook = fixture.repo.appendingPathComponent(".git/hooks/reference-transaction")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let pins = try PinStore(repository: try await fixture.repository(), installID: "i1")

        try await pins.pin([commit])
        try await pins.release([commit])
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        try fixture.git(["update-ref", "refs/heads/proof", commit.hex])
        #expect(FileManager.default.fileExists(atPath: marker.path), "The fixture should prove the hook runs without the guard")
    }

    @Test(arguments: ["", "-lead", "has/slash", "has space", "dots..", String(repeating: "a", count: 65), "ünï"])
    func refusesInstallIDsThatWouldMakeABadRefName(installID: String) async throws {
        let fixture = try GitFixture()
        let repository = try await fixture.repository()
        #expect(throws: GitError.self) { try PinStore(repository: repository, installID: installID) }
    }
}
