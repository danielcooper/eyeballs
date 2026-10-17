import GRDB

/// A value stored in an enum-like column, whose list of values can grow in a later version.
///
/// The schema has no `CHECK` list on these columns, so a newer Eyeballs may write a value this
/// version has never seen. Each conforming enum decodes that value as `.unknown(raw)` instead of
/// failing, and writes it back unchanged.
public protocol OpenEnum: RawRepresentable<String>, Codable, Hashable, Sendable, DatabaseValueConvertible {
    init(rawValue: String)
}

/// Who wrote a comment or opened a thread. The schema's `CHECK` constraint fixes this set.
public enum Participant: String, Codable, Hashable, Sendable, DatabaseValueConvertible {
    case human, agent
}

/// `agent_session.agent`
public enum AgentKind: OpenEnum {
    case claude, other
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "claude": self = .claude
        case "other": self = .other
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .claude: "claude"
        case .other: "other"
        case .unknown(let raw): raw
        }
    }
}

/// `stack.source`: where the list of branches came from.
public enum StackSource: OpenEnum {
    case ghStack, branchList, singleBranch, gitChain
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "gh_stack": self = .ghStack
        case "branch_list": self = .branchList
        case "single_branch": self = .singleBranch
        case "git_chain": self = .gitChain
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .ghStack: "gh_stack"
        case .branchList: "branch_list"
        case .singleBranch: "single_branch"
        case .gitChain: "git_chain"
        case .unknown(let raw): raw
        }
    }
}

/// `stack.state`
public enum StackState: OpenEnum {
    case active, merged, archived
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "active": self = .active
        case "merged": self = .merged
        case "archived": self = .archived
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .active: "active"
        case .merged: "merged"
        case .archived: "archived"
        case .unknown(let raw): raw
        }
    }
}

/// `layer.state`
public enum LayerState: OpenEnum {
    case active, merged, dropped, folded
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "active": self = .active
        case "merged": self = .merged
        case "dropped": self = .dropped
        case "folded": self = .folded
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .active: "active"
        case .merged: "merged"
        case .dropped: "dropped"
        case .folded: "folded"
        case .unknown(let raw): raw
        }
    }
}

/// `snapshot.base_rule`: which rule chose the layer's base. Anything but `parentTip` needs a restack.
public enum BaseRule: OpenEnum {
    case parentTip, recordedBase, forkPoint, mergeBase
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "parent_tip": self = .parentTip
        case "recorded_base": self = .recordedBase
        case "fork_point": self = .forkPoint
        case "merge_base": self = .mergeBase
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .parentTip: "parent_tip"
        case .recordedBase: "recorded_base"
        case .forkPoint: "fork_point"
        case .mergeBase: "merge_base"
        case .unknown(let raw): raw
        }
    }
}

/// `snapshot_file.change`: git's status letter for the file.
public enum FileChangeKind: OpenEnum {
    case added, modified, deleted, renamed, copied, typeChanged
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "A": self = .added
        case "M": self = .modified
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .unknown(let raw): raw
        }
    }
}

/// `revision.trigger`: who caused the revision.
public enum RevisionTrigger: OpenEnum {
    /// The agent ran `eyeballs review`.
    case agentSubmit
    /// You submitted or sent a comment after the branch tips moved.
    case humanStart
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "agent_submit": self = .agentSubmit
        case "human_start": self = .humanStart
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .agentSubmit: "agent_submit"
        case .humanStart: "human_start"
        case .unknown(let raw): raw
        }
    }
}

/// `review.status`: a review moves from draft to submitted, delivered and replied, or is discarded.
public enum ReviewStatus: OpenEnum {
    case draft, submitted, delivered, replied, discarded
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "draft": self = .draft
        case "submitted": self = .submitted
        case "delivered": self = .delivered
        case "replied": self = .replied
        case "discarded": self = .discarded
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .draft: "draft"
        case .submitted: "submitted"
        case .delivered: "delivered"
        case .replied: "replied"
        case .discarded: "discarded"
        case .unknown(let raw): raw
        }
    }
}

/// `review.verdict`
public enum ReviewVerdict: OpenEnum {
    case comment, changesRequested, approved
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "comment": self = .comment
        case "changes_requested": self = .changesRequested
        case "approved": self = .approved
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .comment: "comment"
        case .changesRequested: "changes_requested"
        case .approved: "approved"
        case .unknown(let raw): raw
        }
    }
}

/// `thread.subject`: what the thread is about.
public enum ThreadSubject: OpenEnum {
    case line, file, layer
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "line": self = .line
        case "file": self = .file
        case "layer": self = .layer
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .line: "line"
        case .file: "file"
        case .layer: "layer"
        case .unknown(let raw): raw
        }
    }
}

/// `thread.side`: GitHub's LEFT (`base`) or RIGHT (`head`).
public enum DiffSide: OpenEnum {
    case base, head
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "base": self = .base
        case "head": self = .head
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .base: "base"
        case .head: "head"
        case .unknown(let raw): raw
        }
    }
}

/// `thread.status`. Only you change it, from the window.
public enum ThreadStatus: OpenEnum {
    case open, resolved
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "open": self = .open
        case "resolved": self = .resolved
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .open: "open"
        case .resolved: "resolved"
        case .unknown(let raw): raw
        }
    }
}

/// `anchor.state`: how well a thread's lines survived into a revision.
public enum AnchorState: OpenEnum {
    case original, current, moved, whitespace, changed, relocated, outdated, gone
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "original": self = .original
        case "current": self = .current
        case "moved": self = .moved
        case "whitespace": self = .whitespace
        case "changed": self = .changed
        case "relocated": self = .relocated
        case "outdated": self = .outdated
        case "gone": self = .gone
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .original: "original"
        case .current: "current"
        case .moved: "moved"
        case .whitespace: "whitespace"
        case .changed: "changed"
        case .relocated: "relocated"
        case .outdated: "outdated"
        case .gone: "gone"
        case .unknown(let raw): raw
        }
    }
}

/// `anchor.method`: how the porter placed the anchor. `created` is the thread's origin.
public enum AnchorMethod: OpenEnum {
    case created, sameBlob, diffShift, diffWhitespace, diffInterior, exactSearch, fuzzy, journal, fallback, human
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "created": self = .created
        case "same_blob": self = .sameBlob
        case "diff_shift": self = .diffShift
        case "diff_ws": self = .diffWhitespace
        case "diff_interior": self = .diffInterior
        case "exact_search": self = .exactSearch
        case "fuzzy": self = .fuzzy
        case "journal": self = .journal
        case "fallback": self = .fallback
        case "human": self = .human
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .created: "created"
        case .sameBlob: "same_blob"
        case .diffShift: "diff_shift"
        case .diffWhitespace: "diff_ws"
        case .diffInterior: "diff_interior"
        case .exactSearch: "exact_search"
        case .fuzzy: "fuzzy"
        case .journal: "journal"
        case .fallback: "fallback"
        case .human: "human"
        case .unknown(let raw): raw
        }
    }
}

/// `comment.reply_status`: what the agent says it did about a thread.
public enum AgentReplyStatus: OpenEnum {
    case addressed, declined, question
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "addressed": self = .addressed
        case "declined": self = .declined
        case "question": self = .question
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .addressed: "addressed"
        case .declined: "declined"
        case .question: "question"
        case .unknown(let raw): raw
        }
    }
}

/// One `at:` line from an agent reply: where the fix is, when it is not on the commented lines.
public struct AtRange: Codable, Hashable, Sendable {
    public var path: String
    /// 1-based and inclusive.
    public var start: Int
    public var end: Int

    public init(path: String, start: Int, end: Int) {
        self.path = path
        self.start = start
        self.end = end
    }
}
