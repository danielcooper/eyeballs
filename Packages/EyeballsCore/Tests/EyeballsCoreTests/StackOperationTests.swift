@testable import EyeballsCore
import Foundation
import Testing

/// Fix 9: refuse a snapshot only during a real operation.
struct StackOperationTests {
    @Test(arguments: [("applying", ModifyPhase.applying), ("conflict", .conflict), ("future_phase", .unrecognised)])
    func refusesWhileAModifyIsUnderWay(phase: String, expected: ModifyPhase) async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.writeGitFile("gh-stack-modify-state", #"{"schema_version": 1, "phase": "\#(phase)", "stack_branches": ["models", "api", "web"]}"#)

        await #expect(throws: StackError.midOperation(.modify(expected))) {
            _ = try await stack.reader().ghStack(containing: "api")
        }
    }

    @Test func refusesAModifyStateItCannotRead() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.writeGitFile("gh-stack-modify-state", "{ not json")
        await #expect(throws: StackError.midOperation(.modify(.unrecognised))) {
            _ = try await stack.reader().ghStack(containing: "api")
        }

        try stack.writeGitFile("gh-stack-modify-state", #"{"schema_version": 2, "phase": "pending_submit"}"#)
        await #expect(throws: StackError.midOperation(.modify(.unrecognised))) {
            _ = try await stack.reader().ghStack(containing: "api")
        }
    }

    @Test func readsTheStackWhileAModifyWaitsForSubmitAndReportsRenames() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.writeGitFile("gh-stack-modify-state", #"{"schema_version": 1, "phase": "pending_submit", "renamed_branches": {"old-api": "api"}}"#)

        let found = try await stack.reader().ghStack(containing: "api")
        #expect(found.layers.count == 3)
        #expect(found.renamedBranches == ["old-api": "api"])
    }

    @Test func reportsAnOperationAsAWarningWhenAskedNotToRefuse() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.writeGitFile("gh-stack-modify-state", #"{"schema_version": 1, "phase": "applying"}"#)

        let found = try await stack.reader().ghStack(containing: "api", refuseDuringOperation: false)
        #expect(found.warnings == [.operationInProgress(.modify(.applying))])
    }

    @Test func refusesWhileARebaseOfAStackBranchIsPaused() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        let worktree = try pauseRebaseOfAPI(in: stack)

        let error = await #expect(throws: StackError.self) {
            _ = try await stack.reader().ghStack(containing: "models")
        }
        guard case let .midOperation(.rebase(branch, pausedIn)) = error else {
            Issue.record("Expected a paused rebase, got \(String(describing: error))")
            return
        }
        #expect(branch == "api")
        #expect(pausedIn.path == worktree.path)
        #expect(error?.code == "mid_operation")
    }

    @Test func ignoresAPausedRebaseOfABranchOutsideTheStack() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        _ = try pauseRebaseOfAPI(in: stack)

        let found = try await stack.reader().singleBranch("models")
        #expect(found.layers.map(\.branch) == ["models"])
    }

    @Test func ignoresARebaseLeftInAPrunableWorktree() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        let worktree = stack.git.root.appendingPathComponent("abandoned")
        try stack.git.git(["worktree", "add", "-q", "--detach", worktree.path, "main"])
        try stack.writeGitFile("worktrees/abandoned/rebase-merge/head-name", "refs/heads/api\n")
        await #expect(throws: StackError.self, "The fixture should prove the rebase blocks while its worktree exists") {
            _ = try await stack.reader().ghStack(containing: "api")
        }

        try FileManager.default.removeItem(at: worktree)
        #expect(try stack.git.git(["worktree", "list", "--porcelain"]).contains("prunable"))
        let found = try await stack.reader().ghStack(containing: "api")
        #expect(found.layers.count == 3)
    }

    @Test func refusesAModifyStateLeftInALegacyWorktreeFolder() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.writeGitFile("worktrees/old/gh-stack-modify-state", #"{"phase": "conflict"}"#)
        await #expect(throws: StackError.midOperation(.modify(.conflict))) {
            _ = try await stack.reader().ghStack(containing: "api")
        }
    }

    @Test func warnsAboutAStaleGhStackRebaseState() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.writeGitFile("gh-stack-rebase-state", #"{"phase": "conflict", "conflictBranch": "api"}"#)

        let found = try await stack.reader().ghStack(containing: "api")
        #expect(found.warnings == [.staleRebaseState])
    }

    @Test func readsWorktreeListings() {
        let listing = "worktree /r\0HEAD \(String(repeating: "a", count: 40))\0branch refs/heads/main\0\0"
            + "worktree /r-wt\0HEAD \(String(repeating: "b", count: 40))\0detached\0prunable gitdir file points to non-existent location\0\0"
            + "worktree /bare\0bare\0\0"
        let records = OperationCheck.worktreeRecords(in: Data(listing.utf8))
        #expect(records.map(\.path.path) == ["/r", "/r-wt", "/bare"])
        #expect(records.map(\.branch) == ["main", nil, nil])
        #expect(records.map(\.isPrunable) == [false, true, false])
        #expect(records.map(\.isBare) == [false, false, true])
    }

    /// Starts a rebase of `api` in a linked worktree that stops on a conflict, and returns that worktree.
    private func pauseRebaseOfAPI(in stack: StackFixture) throws -> URL {
        try stack.git.git(["checkout", "-q", "-b", "clash", "models"])
        try stack.git.write("api.txt", "something else\n")
        try stack.git.commit("Clash with api")
        try stack.git.git(["checkout", "-q", "main"])
        let worktree = stack.git.root.appendingPathComponent("api-wt")
        try stack.git.git(["worktree", "add", "-q", worktree.path, "api"])
        #expect(throws: FixtureError.self, "The rebase should stop on a conflict") {
            try stack.git.git(["rebase", "clash"], in: worktree)
        }
        #expect(FileManager.default.fileExists(atPath: stack.git.repo.appendingPathComponent(".git/worktrees/api-wt/rebase-merge").path))
        return worktree
    }
}
