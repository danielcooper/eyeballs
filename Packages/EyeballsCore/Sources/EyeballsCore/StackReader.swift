import Foundation

/// Reads a stack from a repository: its branches, their live tips, and the base each layer's diff
/// starts from.
///
/// It reads gh-stack's catalog file itself and never runs `gh stack`. Each layer's base is the first
/// of these candidates that is an ancestor of its head: the parent's live tip, the base gh-stack
/// recorded, `git merge-base --fork-point`, then `git merge-base`. For layer 1, the parent is both
/// `<trunk>` and `origin/<trunk>`, and the newer result wins. A merged layer is skipped as a parent,
/// as gh-stack does.
///
/// A candidate must also contain the head's merge base with its parent and with the trunk, so a
/// layer never shows commits its parent or trunk already has. A stale recorded base fails this
/// check. When every candidate fails, as after the parent was squash-merged and the layer moved
/// onto the trunk, the base is the trunk's merge base with the head.
///
/// By default each read throws `StackError.midOperation` while a rebase or `gh stack modify` that
/// touches the stack is part way through.
public struct StackReader: Sendable {
    public let repository: GitRepository

    public init(repository: GitRepository) {
        self.repository = repository
    }

    /// The gh-stack stack that has `branch` as a layer.
    ///
    /// Throws `StackError.noCatalog`, `.noStack`, `.unsupportedCatalog`, `.unreadableCatalog`,
    /// `.missingBranch`, `.noCommonHistory` or `.midOperation`.
    public func ghStack(containing branch: String, refuseDuringOperation: Bool = true) async throws -> DiscoveredStack {
        guard let catalog = try GhStackCatalog.load(commonDirectory: repository.commonDirectory) else { throw StackError.noCatalog }
        guard let stack = catalog.stack(containing: branch) else { throw StackError.noStack(branch: branch) }
        let plans = stack.branches.map { entry in
            LayerPlan(
                branch: entry.branch,
                recordedBase: entry.base.flatMap { ObjectID($0) },
                pullRequest: entry.pullRequest.map { StackPullRequest(number: $0.number, url: $0.url) },
                isMerged: entry.pullRequest?.merged == true
            )
        }
        var discovered = try await discover(.ghStack, trunk: stack.trunk.branch, plans: plans, refuseDuringOperation: refuseDuringOperation)
        discovered.ghStackID = stack.id
        discovered.ghStackNumber = stack.number
        discovered.remoteRepository = catalog.repository
        return discovered
    }

    /// One branch reviewed on its own. The trunk is `trunk` if you pass one, else the branch
    /// `origin/HEAD` names, else `main`.
    public func singleBranch(_ branch: String, trunk: String? = nil, refuseDuringOperation: Bool = true) async throws -> DiscoveredStack {
        let trunk = try await resolvedTrunk(trunk)
        let plans = try Self.plans(for: [branch], trunk: trunk)
        return try await discover(.singleBranch, trunk: trunk, plans: plans, refuseDuringOperation: refuseDuringOperation)
    }

    /// An explicit stack, bottom branch first. The trunk follows the same rule as `singleBranch`.
    public func branchList(_ branches: [String], trunk: String? = nil, refuseDuringOperation: Bool = true) async throws -> DiscoveredStack {
        let trunk = try await resolvedTrunk(trunk)
        let plans = try Self.plans(for: branches, trunk: trunk)
        return try await discover(.branchList, trunk: trunk, plans: plans, refuseDuringOperation: refuseDuringOperation)
    }

    /// The branch `origin/HEAD` points at, or `main` when it points at none.
    public func defaultTrunk() async throws -> String {
        let prefix = "refs/remotes/origin/"
        if let target = try await repository.symbolicTarget(of: prefix + "HEAD"), target.hasPrefix(prefix) {
            return String(target.dropFirst(prefix.count))
        }
        return "main"
    }

    // MARK: Layers and bases

    private func discover(_ source: StackSource, trunk: String, plans: [LayerPlan], refuseDuringOperation: Bool) async throws -> DiscoveredStack {
        let operations = try await OperationCheck(repository: repository)
            .run(stackBranches: Set(plans.map(\.branch)), refuse: refuseDuringOperation)
        let tips = try await branchTips()
        let trunkRefs = ["refs/heads/\(trunk)", "refs/remotes/origin/\(trunk)"].filter { tips[$0] != nil }
        guard !trunkRefs.isEmpty else { throw StackError.missingBranch(trunk) }

        var layers: [StackLayer] = []
        var warnings = operations.warnings
        var parentBranch: String?
        for plan in plans {
            guard let head = tips["refs/heads/\(plan.branch)"] else {
                if plan.isMerged {
                    warnings.append(.mergedBranchMissing(branch: plan.branch))
                    continue
                }
                throw StackError.missingBranch(plan.branch)
            }
            let parentRefs = parentBranch.map { ["refs/heads/\($0)"] } ?? trunkRefs
            let floors = try await historyFloors(for: head, refs: Set(parentRefs + trunkRefs), tips: tips)
            var choice = try await newestBase(for: head, parentRefs: parentRefs, tips: tips, recorded: plan.recordedBase, floors: floors)
            if choice == nil {
                choice = try await trunkMergeBase(for: head, trunkRefs: trunkRefs, tips: tips)
            }
            guard let choice else { throw StackError.noCommonHistory(branch: plan.branch) }
            layers.append(StackLayer(
                position: layers.count + 1, branch: plan.branch, head: head, base: choice.base,
                baseRule: choice.rule, parentRef: choice.parentRef, pullRequest: plan.pullRequest, isMerged: plan.isMerged
            ))
            if !plan.isMerged { parentBranch = plan.branch }
        }
        return DiscoveredStack(
            source: source, trunk: trunk, layers: layers, ghStackID: nil, ghStackNumber: nil, remoteRepository: nil,
            renamedBranches: operations.renamedBranches, warnings: warnings
        )
    }

    /// The base from each parent ref, keeping the newest. Only layer 1 has two parent refs.
    private func newestBase(
        for head: ObjectID, parentRefs: [String], tips: [String: ObjectID], recorded: ObjectID?, floors: [ObjectID]
    ) async throws -> BaseChoice? {
        var best: BaseChoice?
        for parentRef in parentRefs {
            guard let parentTip = tips[parentRef],
                  let choice = try await base(for: head, parentRef: parentRef, parentTip: parentTip, recorded: recorded, floors: floors)
            else { continue }
            if let current = best {
                best = try await newer(of: current, and: choice)
            } else {
                best = choice
            }
        }
        return best
    }

    /// Tries the four rules in order, keeping the first candidate that is an ancestor of the head
    /// and contains every floor.
    private func base(for head: ObjectID, parentRef: String, parentTip: ObjectID, recorded: ObjectID?, floors: [ObjectID]) async throws -> BaseChoice? {
        if try await isAcceptable(parentTip, for: head, floors: floors) {
            return BaseChoice(base: parentTip, rule: .parentTip, parentRef: parentRef)
        }
        if let recorded, try await repository.resolveCommit(recorded.hex) != nil,
           try await isAcceptable(recorded, for: head, floors: floors) {
            return BaseChoice(base: recorded, rule: .recordedBase, parentRef: parentRef)
        }
        if let forkPoint = try await repository.forkPoint(upstream: parentRef, of: head.hex),
           try await isAcceptable(forkPoint, for: head, floors: floors) {
            return BaseChoice(base: forkPoint, rule: .forkPoint, parentRef: parentRef)
        }
        if let mergeBase = try await repository.mergeBase(parentTip.hex, head.hex),
           try await isAcceptable(mergeBase, for: head, floors: floors) {
            return BaseChoice(base: mergeBase, rule: .mergeBase, parentRef: parentRef)
        }
        return nil
    }

    private func isAcceptable(_ candidate: ObjectID, for head: ObjectID, floors: [ObjectID]) async throws -> Bool {
        guard try await repository.isAncestor(candidate.hex, of: head.hex) else { return false }
        for floor in floors where try await !repository.isAncestor(floor.hex, of: candidate.hex) {
            return false
        }
        return true
    }

    /// The head's merge base with each ref. A base older than any of these would show commits that ref already has.
    private func historyFloors(for head: ObjectID, refs: Set<String>, tips: [String: ObjectID]) async throws -> [ObjectID] {
        var floors: Set<ObjectID> = []
        for ref in refs.sorted() {
            guard let tip = tips[ref], let floor = try await repository.mergeBase(tip.hex, head.hex) else { continue }
            floors.insert(floor)
        }
        return floors.sorted()
    }

    /// The newest merge base of the head with the trunk, for a layer whose parent is no longer under it.
    private func trunkMergeBase(for head: ObjectID, trunkRefs: [String], tips: [String: ObjectID]) async throws -> BaseChoice? {
        var best: BaseChoice?
        for trunkRef in trunkRefs {
            guard let tip = tips[trunkRef], let mergeBase = try await repository.mergeBase(tip.hex, head.hex) else { continue }
            let choice = BaseChoice(base: mergeBase, rule: .mergeBase, parentRef: trunkRef)
            if let current = best {
                best = try await newer(of: current, and: choice)
            } else {
                best = choice
            }
        }
        return best
    }

    /// The choice whose base descends from the other's. When neither does, or both bases are the
    /// same commit, the better rule wins, and then the first choice, which is the local trunk.
    private func newer(of first: BaseChoice, and second: BaseChoice) async throws -> BaseChoice {
        if first.base != second.base {
            if try await repository.isAncestor(first.base.hex, of: second.base.hex) { return second }
            if try await repository.isAncestor(second.base.hex, of: first.base.hex) { return first }
        }
        return second.rule < first.rule ? second : first
    }

    /// Every local branch tip and every `origin` tip, from one `git for-each-ref`.
    private func branchTips() async throws -> [String: ObjectID] {
        let references = try await repository.references(under: ["refs/heads/", "refs/remotes/origin/"])
        return Dictionary(references.map { ($0.name, $0.target) }, uniquingKeysWith: { first, _ in first })
    }

    private func resolvedTrunk(_ trunk: String?) async throws -> String {
        if let trunk {
            return trunk
        }
        return try await defaultTrunk()
    }

    static func plans(for branches: [String], trunk: String) throws -> [LayerPlan] {
        guard !branches.isEmpty else { throw StackError.badBranchList("Name at least one branch to review.") }
        guard Set(branches).count == branches.count else { throw StackError.badBranchList("List each branch only once.") }
        guard !branches.contains(trunk) else { throw StackError.badBranchList("The trunk cannot also be a layer. Name a different trunk.") }
        guard branches.allSatisfy(isPlausibleBranchName) else {
            throw StackError.badBranchList("Branch names cannot be empty, start with \"-\" or hold a newline.")
        }
        return branches.map { LayerPlan(branch: $0, recordedBase: nil, pullRequest: nil, isMerged: false) }
    }

    private static func isPlausibleBranchName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.contains("\n") && !name.contains("\0")
    }
}

struct LayerPlan {
    var branch: String
    var recordedBase: ObjectID?
    var pullRequest: StackPullRequest?
    var isMerged: Bool
}

struct BaseChoice {
    var base: ObjectID
    var rule: BaseRule
    var parentRef: String
}
