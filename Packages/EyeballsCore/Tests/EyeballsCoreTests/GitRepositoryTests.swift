import EyeballsCore
import Foundation
import Testing

struct GitRepositoryTests {
    @Test func findsTheRepositoryFromItsWorkTree() async throws {
        let fixture = try GitFixture()
        try fixture.write("Sources/App/main.swift", "print(1)\n")
        try fixture.commit("one")

        for folder in [fixture.repo, fixture.repo.appendingPathComponent("Sources/App")] {
            let repository = try await GitRepository.locate(from: folder)
            #expect(repository.workTree?.path == fixture.repo.path)
            #expect(repository.gitDirectory.path == fixture.repo.appendingPathComponent(".git").path)
            #expect(repository.commonDirectory.path == fixture.repo.appendingPathComponent(".git").path)
            #expect(!repository.isLinkedWorktree)
        }
    }

    @Test func findsTheRepositoryFromInsideItsGitFolder() async throws {
        let fixture = try GitFixture()
        try fixture.commit("one")

        for folder in [fixture.repo.appendingPathComponent(".git"), fixture.repo.appendingPathComponent(".git/refs/heads")] {
            let repository = try await GitRepository.locate(from: folder)
            #expect(repository.workTree?.path == fixture.repo.path)
            #expect(repository.commonDirectory.path == fixture.repo.appendingPathComponent(".git").path)
        }
    }

    @Test func findsALinkedWorktreeAndItsCommonFolder() async throws {
        let fixture = try GitFixture()
        try fixture.commit("one")
        let linked = fixture.root.appendingPathComponent("linked")
        try fixture.git(["worktree", "add", "-q", "-b", "feature", linked.path])
        let adminFolder = fixture.repo.appendingPathComponent(".git/worktrees/linked")

        for folder in [linked, adminFolder] {
            let repository = try await GitRepository.locate(from: folder)
            #expect(repository.workTree?.path == linked.path)
            #expect(repository.gitDirectory.path == adminFolder.path)
            #expect(repository.commonDirectory.path == fixture.repo.appendingPathComponent(".git").path)
            #expect(repository.isLinkedWorktree)
        }
        let fromLinked = try await GitRepository.locate(from: linked)
        #expect(try await fromLinked.currentBranch() == "feature")
    }

    @Test func findsABareRepository() async throws {
        let fixture = try GitFixture(bare: true)
        let repository = try await GitRepository.locate(from: fixture.repo)
        #expect(repository.workTree == nil)
        #expect(repository.gitDirectory.path == fixture.repo.path)
        #expect(repository.commonDirectory.path == fixture.repo.path)
    }

    @Test func saysWhenAFolderIsNotInARepository() async throws {
        let fixture = try GitFixture()
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        await #expect(throws: GitError.notARepository) {
            _ = try await GitRepository.locate(from: outside)
        }
    }
}
