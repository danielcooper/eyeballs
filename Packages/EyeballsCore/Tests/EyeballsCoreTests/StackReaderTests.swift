import EyeballsCore
import Foundation
import Testing

struct StackReaderTests {
    @Test func readsAStackWhoseLayersSitOnTheirParents() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()

        let found = try await stack.reader().ghStack(containing: "api")
        #expect(found.source == .ghStack)
        #expect(found.trunk == "main")
        #expect(found.name == "web")
        #expect(found.ghStackID == "S_kwDO42")
        #expect(found.ghStackNumber == 11280)
        #expect(found.remoteRepository == "owner/shop")
        #expect(found.layers.map(\.position) == [1, 2, 3])
        #expect(found.layers.map(\.branch) == ["models", "api", "web"])
        #expect(found.layers.map(\.head) == [stack.tip("models"), stack.tip("api"), stack.tip("web")])
        #expect(found.layers.map(\.base) == [stack.root, stack.tip("models"), stack.tip("api")])
        #expect(found.layers.map(\.baseRule) == [.parentTip, .parentTip, .parentTip])
        #expect(found.layers.map(\.parentRef) == ["refs/heads/main", "refs/heads/models", "refs/heads/api"])
        #expect(found.layers.map { $0.pullRequest?.number } == [811, 812, 813])
        #expect(found.layers.allSatisfy { !$0.needsRestack && !$0.isMerged && !$0.isEmpty })
        #expect(found.warnings.isEmpty)
    }

    @Test func trustsLiveBranchTipsOverTheCatalog() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog(staleHeads: true)
        try stack.git.git(["checkout", "-q", "api"])
        try stack.git.write("api.txt", "api line 1\napi line 2\napi line 3\n")
        let newTip = try stack.git.commit("More api")

        let found = try await stack.reader().ghStack(containing: "models")
        #expect(found.layers[1].head == newTip)
        #expect(found.layers[2].base == stack.tip("api"))
        #expect(found.layers[2].baseRule == .recordedBase)
        #expect(found.layers[2].needsRestack)
    }

    @Test func fallsBackToTheRecordedBaseWhenTheParentWasRewritten() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try amend("models", in: stack)

        let found = try await stack.reader().ghStack(containing: "web")
        #expect(found.layers[0].baseRule == .parentTip)
        #expect(found.layers[1].baseRule == .recordedBase)
        #expect(found.layers[1].base == stack.tip("models"))
        #expect(found.layers[1].needsRestack)
        #expect(found.layers[2].baseRule == .parentTip)
    }

    @Test func fallsBackToTheForkPointWithoutARecordedBase() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog(recordBases: false)
        try amend("models", in: stack)

        let found = try await stack.reader().ghStack(containing: "api")
        #expect(found.layers[1].baseRule == .forkPoint)
        #expect(found.layers[1].base == stack.tip("models"))
    }

    @Test func fallsBackToTheMergeBaseWithoutAReflog() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog(recordBases: false)
        try amend("models", in: stack)
        try stack.git.git(["reflog", "expire", "--expire=now", "--all"])

        let found = try await stack.reader().ghStack(containing: "api")
        #expect(found.layers[1].baseRule == .mergeBase)
        #expect(found.layers[1].base == stack.root)
        #expect(found.layers[1].parentRef == "refs/heads/models")
    }

    @Test func ignoresARecordedBaseThatWouldShowTrunkCommits() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.git.git(["checkout", "-q", "main"])
        try stack.git.write("trunk.txt", "first landing\n")
        let landed = try stack.git.commit("Landed on main")
        try stack.git.git(["checkout", "-q", "models"])
        try stack.git.git(["rebase", "-q", "main"])
        try stack.git.git(["checkout", "-q", "main"])
        try stack.git.write("trunk.txt", "second landing\n")
        try stack.git.commit("Landed again")

        let found = try await stack.reader().ghStack(containing: "models")
        #expect(found.layers[0].base == landed)
        #expect(found.layers[0].baseRule == .forkPoint)
        #expect(try await stack.git.repository().commits(from: found.layers[0].base, to: found.layers[0].head).count == 1)
    }

    @Test func movesALayerOntoTheTrunkWhenItsParentWasSquashMerged() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.git.git(["checkout", "-q", "main"])
        try stack.git.write("models.txt", "models line 1\nmodels line 2\n")
        let squash = try stack.git.commit("Add models (#811)")
        try stack.git.git(["rebase", "-q", "--onto", "main", stack.tip("models").hex, "api"])
        try stack.git.git(["checkout", "-q", "main"])

        let found = try await stack.reader().ghStack(containing: "api")
        #expect(found.layers[1].base == squash)
        #expect(found.layers[1].baseRule == .mergeBase)
        #expect(found.layers[1].parentRef == "refs/heads/main")
        #expect(found.layers[1].needsRestack)
        #expect(try await stack.git.repository().commits(from: found.layers[1].base, to: found.layers[1].head).count == 1)
    }

    @Test func usesOriginsTrunkWhenTheBottomLayerSitsOnIt() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog(recordBases: false)
        try stack.git.git(["checkout", "-q", "-b", "upstream", "main"])
        try stack.git.write("upstream.txt", "landed upstream\n")
        let upstream = try stack.git.commit("Landed upstream")
        try stack.git.git(["update-ref", "refs/remotes/origin/main", upstream.hex])
        try stack.git.git(["checkout", "-q", "models"])
        try stack.git.git(["rebase", "-q", "upstream"])
        try stack.git.git(["checkout", "-q", "main"])

        let found = try await stack.reader().ghStack(containing: "models")
        #expect(found.layers[0].base == upstream)
        #expect(found.layers[0].baseRule == .parentTip)
        #expect(found.layers[0].parentRef == "refs/remotes/origin/main")
    }

    @Test func keepsTheLocalTrunkWhenOriginHasMovedOn() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.git.git(["checkout", "-q", "-b", "upstream", "main"])
        let upstream = try stack.git.commit("Landed upstream")
        try stack.git.git(["update-ref", "refs/remotes/origin/main", upstream.hex])
        try stack.git.git(["checkout", "-q", "main"])

        let found = try await stack.reader().ghStack(containing: "models")
        #expect(found.layers[0].base == stack.root)
        #expect(found.layers[0].baseRule == .parentTip)
        #expect(found.layers[0].parentRef == "refs/heads/main")
    }

    @Test func usesOriginsTrunkWhenThereIsNoLocalOne() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.git.git(["update-ref", "refs/remotes/origin/main", stack.root.hex])
        try stack.git.git(["checkout", "-q", "--detach"])
        try stack.git.git(["branch", "-q", "-D", "main"])

        let found = try await stack.reader().ghStack(containing: "models")
        #expect(found.layers[0].parentRef == "refs/remotes/origin/main")
        #expect(found.layers[0].base == stack.root)
    }

    @Test func skipsAMergedLayerAsAParent() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog(merged: ["models"])

        let found = try await stack.reader().ghStack(containing: "api")
        #expect(found.layers.map(\.isMerged) == [true, false, false])
        #expect(found.layers[1].parentRef == "refs/heads/main")
        #expect(found.layers[1].base == stack.root)
    }

    @Test func leavesOutAMergedLayerWhoseBranchIsGone() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog(merged: ["models"])
        try stack.git.git(["branch", "-q", "-D", "models"])

        let found = try await stack.reader().ghStack(containing: "web")
        #expect(found.layers.map(\.branch) == ["api", "web"])
        #expect(found.layers.map(\.position) == [1, 2])
        #expect(found.warnings == [.mergedBranchMissing(branch: "models")])
    }

    @Test func refusesAStackWithAMissingBranch() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog()
        try stack.git.git(["branch", "-q", "-D", "web"])
        await #expect(throws: StackError.missingBranch("web")) {
            _ = try await stack.reader().ghStack(containing: "api")
        }
    }

    @Test func saysWhenThereIsNoCatalogOrNoStack() async throws {
        let stack = try StackFixture()
        await #expect(throws: StackError.noCatalog) { _ = try await stack.reader().ghStack(containing: "api") }
        try stack.writeCatalog()
        await #expect(throws: StackError.noStack(branch: "main")) { _ = try await stack.reader().ghStack(containing: "main") }
        await #expect(throws: StackError.noStack(branch: "other")) { _ = try await stack.reader().ghStack(containing: "other") }
    }

    @Test func refusesANewerCatalogSchema() async throws {
        let stack = try StackFixture()
        try stack.writeCatalog(schemaVersion: 2)
        await #expect(throws: StackError.unsupportedCatalog(schemaVersion: 2)) {
            _ = try await stack.reader().ghStack(containing: "api")
        }
    }

    @Test func refusesABranchWithNoHistoryInCommon() async throws {
        let stack = try StackFixture()
        let orphan = try stack.git.commitTree([], parent: nil, message: "unrelated")
        try stack.git.git(["update-ref", "refs/heads/orphan", orphan.hex])
        await #expect(throws: StackError.noCommonHistory(branch: "orphan")) {
            _ = try await stack.reader().singleBranch("orphan")
        }
    }

    @Test func readsASingleBranchAgainstTheTrunkOriginNames() async throws {
        let stack = try StackFixture()
        try stack.git.git(["branch", "develop", stack.tip("models").hex])
        try stack.git.git(["update-ref", "refs/remotes/origin/develop", stack.tip("models").hex])
        try stack.git.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"])
        let reader = try await stack.reader()

        #expect(try await reader.defaultTrunk() == "develop")
        let found = try await reader.singleBranch("api")
        #expect(found.source == .singleBranch)
        #expect(found.trunk == "develop")
        #expect(found.layers.map(\.branch) == ["api"])
        #expect(found.layers[0].base == stack.tip("models"))

        let againstMain = try await reader.singleBranch("api", trunk: "main")
        #expect(againstMain.layers[0].base == stack.root)
    }

    @Test func readsASingleBranchAgainstMainWhenOriginNamesNothing() async throws {
        let stack = try StackFixture()
        let found = try await stack.reader().singleBranch("models")
        #expect(found.trunk == "main")
        #expect(found.layers[0].base == stack.root)
        #expect(found.layers[0].baseRule == .parentTip)
    }

    @Test func readsAnExplicitBranchListBottomFirst() async throws {
        let stack = try StackFixture()
        let found = try await stack.reader().branchList(["models", "web"], trunk: "main")
        #expect(found.source == .branchList)
        #expect(found.layers.map(\.branch) == ["models", "web"])
        #expect(found.layers[1].parentRef == "refs/heads/models")
        #expect(found.layers[1].base == stack.tip("models"))
        #expect(found.layers[1].baseRule == .parentTip)
    }

    @Test(arguments: [[], ["api", "api"], ["main", "api"], ["-x"]])
    func refusesBranchListsThatMakeNoStack(branches: [String]) async throws {
        let stack = try StackFixture()
        let reader = try await stack.reader()
        await #expect(throws: StackError.self) { _ = try await reader.branchList(branches, trunk: "main") }
    }

    /// Rewrites a branch's tip, as `git commit --amend` does, leaving its children on the old tip.
    private func amend(_ branch: String, in stack: StackFixture) throws {
        try stack.git.git(["checkout", "-q", branch])
        try stack.git.git(["commit", "-q", "--amend", "--allow-empty", "-m", "Rewritten \(branch)"])
        try stack.git.git(["checkout", "-q", "main"])
    }
}

struct StackCatalogTests {
    @Test func decodesTheShapeGhStackWrites() throws {
        let json = """
        {"schemaVersion": 1, "repository": "owner/shop", "stacks": [{
          "id": "S_1", "number": 7, "trunk": {"branch": "main", "head": "\(String(repeating: "a", count: 40))"},
          "branches": [
            {"branch": "models", "head": "\(String(repeating: "b", count: 40))", "base": "\(String(repeating: "a", count: 40))",
             "pullRequest": {"number": 811, "id": "PR_1", "url": "https://github.com/owner/shop/pull/811", "merged": true}},
            {"branch": "api"}
          ]}]}
        """
        let catalog = try GhStackCatalog.decode(Data(json.utf8))
        #expect(catalog.repository == "owner/shop")
        let stack = try #require(catalog.stack(containing: "api"))
        #expect(stack.id == "S_1" && stack.number == 7)
        #expect(stack.branches.map(\.branch) == ["models", "api"])
        #expect(stack.branches[0].pullRequest == GhStackPullRequest(number: 811, id: "PR_1", url: "https://github.com/owner/shop/pull/811", merged: true))
        #expect(stack.branches[1].base == nil)
        #expect(catalog.stack(containing: "main") == nil)
    }

    @Test func refusesNewerSchemasAndFilesInTheWrongShape() {
        #expect(throws: StackError.unsupportedCatalog(schemaVersion: 2)) { try GhStackCatalog.decode(Data(#"{"schemaVersion": 2, "stacks": "anything"}"#.utf8)) }
        #expect(throws: StackError.unreadableCatalog) { try GhStackCatalog.decode(Data("not json".utf8)) }
        #expect(throws: StackError.unreadableCatalog) { try GhStackCatalog.decode(Data(#"{"schemaVersion": 1, "stacks": [{"branches": []}]}"#.utf8)) }
    }

    @Test func joinsLegacyWorktreeCatalogsWhenTheCommonOneIsMissing() throws {
        let fixture = try GitFixture()
        let common = fixture.repo.appendingPathComponent(".git")
        #expect(try GhStackCatalog.load(commonDirectory: common) == nil)

        let one = #"{"schemaVersion": 1, "repository": "owner/shop", "stacks": [{"trunk": {"branch": "main"}, "branches": [{"branch": "a"}]}]}"#
        let two = #"{"schemaVersion": 1, "stacks": [{"trunk": {"branch": "main"}, "branches": [{"branch": "a"}]}, {"trunk": {"branch": "main"}, "branches": [{"branch": "b"}]}]}"#
        for (name, json) in [("wt1", one), ("wt2", two)] {
            let folder = common.appendingPathComponent("worktrees/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: folder.appendingPathComponent("gh-stack"))
        }

        let catalog = try #require(try GhStackCatalog.load(commonDirectory: common))
        #expect(catalog.repository == "owner/shop")
        #expect(catalog.stacks.map { $0.branches.map(\.branch) } == [["a"], ["b"]])

        try Data(#"{"schemaVersion": 1, "stacks": []}"#.utf8).write(to: common.appendingPathComponent("gh-stack"))
        #expect(try GhStackCatalog.load(commonDirectory: common)?.stacks.isEmpty == true)
    }
}
