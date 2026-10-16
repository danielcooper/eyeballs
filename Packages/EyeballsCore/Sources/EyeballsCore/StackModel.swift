import Foundation

/// A stack as it stands in the repository right now, bottom layer first.
public struct DiscoveredStack: Hashable, Sendable {
    public var source: StackSource
    public var trunk: String
    /// Layer 1 is the bottom, so `layers[0].position == 1`.
    public var layers: [StackLayer]
    /// gh-stack's own ID and number, which change after `gh stack modify` and a submit.
    public var ghStackID: String?
    public var ghStackNumber: Int?
    /// The GitHub repository the catalog names, such as `owner/name`.
    public var remoteRepository: String?
    /// Old branch name to new, from a `gh stack modify` waiting for `gh stack submit`. Use it to
    /// match a renamed branch to its layer.
    public var renamedBranches: [String: String]
    public var warnings: [StackWarning]

    /// The top branch, which names a new stack.
    public var name: String { layers.last?.branch ?? trunk }
}

/// Where a stack's list of branches came from. The raw values match the `stack.source` column.
public enum StackSource: String, Hashable, Sendable {
    case ghStack = "gh_stack"
    case branchList = "branch_list"
    case singleBranch = "single_branch"
}

/// One branch of a stack, with the base its diff starts from.
public struct StackLayer: Hashable, Sendable {
    /// 1 is the bottom layer.
    public var position: Int
    public var branch: String
    /// The live tip of `refs/heads/<branch>`.
    public var head: ObjectID
    public var base: ObjectID
    public var baseRule: BaseRule
    /// The ref the base was worked out against, such as `refs/heads/models` or `refs/remotes/origin/main`.
    public var parentRef: String
    public var pullRequest: StackPullRequest?
    /// True when gh-stack says this layer's PR has merged.
    public var isMerged: Bool

    /// Every rule but `parentTip` means the branch no longer sits on its parent's tip.
    public var needsRestack: Bool { baseRule != .parentTip }
    /// True when the layer has no commits of its own.
    public var isEmpty: Bool { base == head }
}

public struct StackPullRequest: Hashable, Sendable {
    public var number: Int
    public var url: String?
}

/// How a layer's base was chosen. The rules are tried in this order, and the first candidate
/// that is an ancestor of the head wins. The raw values match the `snapshot.base_rule` column.
public enum BaseRule: String, Hashable, Sendable, CaseIterable, Comparable {
    /// The parent branch's live tip.
    case parentTip = "parent_tip"
    /// The parent tip gh-stack recorded at its last sync or rebase.
    case recordedBase = "recorded_base"
    /// `git merge-base --fork-point`, from the parent ref's reflog.
    case forkPoint = "fork_point"
    /// `git merge-base` of the parent tip and the head.
    case mergeBase = "merge_base"

    public static func < (lhs: BaseRule, rhs: BaseRule) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int {
        switch self {
        case .parentTip: 0
        case .recordedBase: 1
        case .forkPoint: 2
        case .mergeBase: 3
        }
    }
}

/// Something worth telling you that does not stop the review.
public enum StackWarning: Hashable, Sendable, CustomStringConvertible {
    /// gh-stack left a `gh-stack-rebase-state` file, but no paused git rebase touches this stack.
    case staleRebaseState
    /// gh-stack says this layer merged, and its branch is gone, so it is left out.
    case mergedBranchMissing(branch: String)
    /// An operation is in progress, and the caller asked not to refuse during one.
    case operationInProgress(MidOperation)

    public var description: String {
        switch self {
        case .staleRebaseState:
            "gh-stack left a rebase state file, but no rebase of this stack is paused. The file looks stale."
        case let .mergedBranchMissing(branch):
            "Layer \(branch.escapingControlCharacters) merged and its branch is gone, so it is left out."
        case let .operationInProgress(operation):
            operation.description
        }
    }
}

/// A rebase or `gh stack modify` that is part way through.
public enum MidOperation: Hashable, Sendable, CustomStringConvertible {
    /// A `gh stack modify` in its applying or conflict phase, or in a phase gh-stack itself would refuse.
    case modify(ModifyPhase)
    /// A paused `git rebase` or `git am` that touches `branch`, in the worktree at `worktree`.
    case rebase(branch: String, worktree: URL)

    public var description: String {
        switch self {
        case .modify(.applying):
            "A gh stack modify was interrupted. Run gh stack modify --abort or --continue, then try again."
        case .modify(.conflict):
            "A gh stack modify stopped on a conflict. Resolve it and run gh stack modify --continue, then try again."
        case .modify(.unrecognised):
            "gh-stack's modify state file is in a phase Eyeballs does not know. Finish the modify with gh-stack, then try again."
        case let .rebase(branch, worktree):
            "A rebase of \(branch.escapingControlCharacters) is paused in \(worktree.path.escapingControlCharacters). Finish it, then try again."
        }
    }
}

public enum ModifyPhase: String, Hashable, Sendable {
    case applying
    case conflict
    /// A phase or schema version newer than gh-stack v0.2.1, or a file that cannot be read.
    case unrecognised
}

public enum StackError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The repository has no gh-stack catalog.
    case noCatalog
    /// No gh-stack stack has this branch as a layer.
    case noStack(branch: String)
    /// The catalog's schema version is newer than Eyeballs can read.
    case unsupportedCatalog(schemaVersion: Int)
    /// The catalog is not JSON in gh-stack's shape.
    case unreadableCatalog
    /// A branch the stack needs has no `refs/heads/` ref.
    case missingBranch(String)
    /// No base rule found a common ancestor for this branch.
    case noCommonHistory(branch: String)
    /// The branch list cannot make a stack. The message says why.
    case badBranchList(String)
    case midOperation(MidOperation)

    /// The error code the socket and the CLI use.
    public var code: String {
        switch self {
        case .noCatalog, .noStack: "no_stack"
        case .unsupportedCatalog: "unsupported_catalog"
        case .unreadableCatalog, .missingBranch, .noCommonHistory, .badBranchList: "bad_input"
        case .midOperation: "mid_operation"
        }
    }

    public var description: String {
        switch self {
        case .noCatalog:
            "This repository has no gh-stack catalog. Name the branches to review instead."
        case .noStack:
            "No gh-stack stack has this branch as a layer."
        case let .unsupportedCatalog(version):
            "The gh-stack catalog uses schema version \(version), and Eyeballs reads version \(GhStackCatalog.supportedSchemaVersion). Update Eyeballs."
        case .unreadableCatalog:
            "The gh-stack catalog is not JSON in the shape gh-stack writes."
        case let .missingBranch(branch):
            "The stack needs branch \(branch.escapingControlCharacters), and the repository has no such branch."
        case let .noCommonHistory(branch):
            "Branch \(branch.escapingControlCharacters) shares no history with its parent, so it has no base."
        case let .badBranchList(problem):
            problem
        case let .midOperation(operation):
            operation.description
        }
    }
}
