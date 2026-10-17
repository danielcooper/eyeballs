/// A stack as results show it: `{"id":"s3","name":"checkout-v2","source":"gh_stack","trunk":"main","repo":"/Users/alex/src/shop"}`.
public struct StackSummary: Codable, Sendable, Hashable {
    public var id: StackID
    public var name: String
    public var source: StackSource
    public var trunk: String
    /// The repo's top-level folder.
    public var repo: String

    public init(id: StackID, name: String, source: StackSource, trunk: String, repo: String) {
        self.id = id
        self.name = name
        self.source = source
        self.trunk = trunk
        self.repo = repo
    }
}

public struct StackSource: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let ghStack: StackSource = "gh_stack"
    public static let branchList: StackSource = "branch_list"
    public static let singleBranch: StackSource = "single_branch"
}

/// The layer a thread lives on: `{"position":2,"branch":"api-client","pr":812,"checkout":"…"}`.
public struct ThreadLayer: Codable, Sendable, Hashable {
    /// 1 is the bottom layer.
    public var position: Int
    public var branch: String
    public var pr: Int?
    /// Set only when the branch is checked out in a different worktree from the agent's.
    public var checkout: String?

    public init(position: Int, branch: String, pr: Int? = nil, checkout: String? = nil) {
        self.position = position
        self.branch = branch
        self.pr = pr
        self.checkout = checkout
    }
}

/// A problem that did not stop the command: `{"code":"dirty_worktree","message":"…","thread":null}`.
public struct Warning: Codable, Sendable, Hashable {
    public var code: WarningCode
    public var message: String
    /// Set when the warning is about one thread, such as `thread_resolved`.
    public var thread: ThreadID?

    public init(code: WarningCode, message: String, thread: ThreadID? = nil) {
        self.code = code
        self.message = message
        self.thread = thread
    }
}

public struct WarningCode: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let notDriver: WarningCode = "not_driver"
    public static let threadResolved: WarningCode = "thread_resolved"
    public static let dirtyWorktree: WarningCode = "dirty_worktree"
}

/// What the agent should do next. Each result's text ends with the same advice in words.
public struct NextStep: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let runWaitInBackground: NextStep = "run_wait_in_background"
    public static let endTurn: NextStep = "end_turn"
    public static let runInbox: NextStep = "run_inbox"
    public static let replyThenReview: NextStep = "reply_then_review"
    public static let replyRemaining: NextStep = "reply_remaining"
    public static let runReview: NextStep = "run_review"
    public static let stop: NextStep = "stop"
}

/// What a driver's Claude process has connected: a background `wait`, a `watch` monitor, or both.
public struct Listener: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let wait: Listener = "wait"
    public static let monitor: Listener = "monitor"
}

/// The reviewer's verdict on a submitted review.
public struct Verdict: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let comment: Verdict = "comment"
    public static let changesRequested: Verdict = "changes_requested"
    public static let approved: Verdict = "approved"
}

/// Where a thread's anchor landed at a revision.
public struct AnchorState: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let original: AnchorState = "original"
    public static let current: AnchorState = "current"
    public static let moved: AnchorState = "moved"
    public static let whitespace: AnchorState = "whitespace"
    public static let changed: AnchorState = "changed"
    public static let relocated: AnchorState = "relocated"
    public static let outdated: AnchorState = "outdated"
    public static let gone: AnchorState = "gone"
}

/// Why a thread waits on the agent.
public struct ThreadKind: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The reviewer's first comment.
    public static let new: ThreadKind = "new"
    /// The reviewer replied after the agent's reply.
    public static let followUp: ThreadKind = "follow-up"
    /// The reviewer answered the agent's question.
    public static let answer: ThreadKind = "answer"
    /// The reviewer reopened a resolved thread.
    public static let reopened: ThreadKind = "reopened"
}

/// What a thread is on: a line range, a whole file, or a whole layer.
public struct ThreadSubject: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let line: ThreadSubject = "line"
    public static let file: ThreadSubject = "file"
    public static let layer: ThreadSubject = "layer"
}

/// The side of the diff a thread is on, as GitHub's LEFT and RIGHT.
public struct DiffSide: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let base: DiffSide = "base"
    public static let head: DiffSide = "head"
}

/// Whether a thread is open or resolved. Only the reviewer changes it.
public struct ThreadStatus: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let open: ThreadStatus = "open"
    public static let resolved: ThreadStatus = "resolved"
}

/// Who wrote a comment.
public struct CommentAuthor: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let human: CommentAuthor = "human"
    public static let agent: CommentAuthor = "agent"
}

/// The agent's answer to a thread. These three cover every case, so the list is closed.
public enum ReplyStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// The agent changed code for it.
    case addressed
    /// The agent chose not to change it, and says why.
    case declined
    /// The agent needs the reviewer's decision.
    case question
}
