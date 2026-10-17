/// `eyeballs inbox`: every thread that waits on the agent, bottom layer first.
public struct InboxArguments: Codable, Sendable, Hashable, ValidatedArguments {
    public var stack: StackReference?
    /// 1 is the first page.
    public var page: Int
    /// Show the inbox without marking anything delivered.
    public var peek: Bool

    public init(stack: StackReference? = nil, page: Int = 1, peek: Bool = false) {
        self.stack = stack
        self.page = page
        self.peek = peek
    }

    public func validate() throws {
        guard page >= 1 else { throw EyeballsError.badInput("The inbox page must be 1 or more.") }
    }
}

/// What `eyeballs inbox` returns. `status` says which kind of answer it is.
public struct InboxResult: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.inbox/1"
    public private(set) var ok = true
    public var status: InboxStatus
    public var stack: StackSummary?
    public var revision: Int?
    /// From `git config user.name`, or "the reviewer" when that is unset.
    public var reviewer: String
    public var reviews: [InboxReview]
    public var threads: [InboxThread]
    /// True when more pages follow.
    public var more: Bool
    public var nextPage: Int?
    public var next: NextStep

    public init(status: InboxStatus, stack: StackSummary?, revision: Int?, reviewer: String, reviews: [InboxReview] = [],
                threads: [InboxThread] = [], more: Bool = false, nextPage: Int? = nil, next: NextStep) {
        self.status = status
        self.stack = stack
        self.revision = revision
        self.reviewer = reviewer
        self.reviews = reviews
        self.threads = threads
        self.more = more
        self.nextPage = nextPage
        self.next = next
    }

    enum CodingKeys: String, CodingKey {
        case schema, ok, status, stack, revision, reviewer, reviews, threads, more
        case nextPage = "next_page"
        case next
    }
}

public struct InboxStatus: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let threads: InboxStatus = "threads"
    public static let approved: InboxStatus = "approved"
    public static let closed: InboxStatus = "closed"
    /// Another live session drives the stack. `inbox` still exits 0.
    public static let notDriver: InboxStatus = "not_driver"
    public static let nothing: InboxStatus = "nothing"
}

/// A submitted review in the inbox: `{"id":7,"verdict":"changes_requested","body":"…","submitted_at":"2026-10-16T14:02:11Z"}`.
public struct InboxReview: Codable, Sendable, Hashable {
    public var id: Int
    public var verdict: Verdict
    public var body: String
    /// ISO 8601, UTC.
    public var submittedAt: String

    public init(id: Int, verdict: Verdict, body: String, submittedAt: String) {
        self.id = id
        self.verdict = verdict
        self.body = body
        self.submittedAt = submittedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, verdict, body
        case submittedAt = "submitted_at"
    }
}

/// One thread that waits on the agent.
public struct InboxThread: Codable, Sendable, Hashable {
    public var id: ThreadID
    public var kind: ThreadKind
    /// The review the newest comment belongs to. Nil for a Send now comment.
    public var review: Int?
    /// True when an earlier `inbox` showed this thread. It is still included.
    public var shownBefore: Bool
    public var layer: ThreadLayer
    public var subject: ThreadSubject
    public var side: DiffSide?
    public var path: String?
    public var start: Int?
    public var end: Int?
    /// The short head commit of the layer at this revision.
    public var commit: String?
    public var anchor: AnchorState
    /// The revision the reviewer was looking at when they wrote the newest comment.
    public var commentedOn: Int
    /// The covered lines only, at most 12.
    public var code: [String]
    /// The original lines, for `changed` and `outdated` anchors.
    public var original: [String]?
    /// Older comments, each cut to 300 characters.
    public var history: [HistoryComment]
    /// The reviewer's newest comment, in full.
    public var comment: InboxComment

    public init(id: ThreadID, kind: ThreadKind, review: Int?, shownBefore: Bool, layer: ThreadLayer, subject: ThreadSubject,
                side: DiffSide?, path: String?, start: Int?, end: Int?, commit: String?, anchor: AnchorState, commentedOn: Int,
                code: [String], original: [String]?, history: [HistoryComment], comment: InboxComment) {
        self.id = id
        self.kind = kind
        self.review = review
        self.shownBefore = shownBefore
        self.layer = layer
        self.subject = subject
        self.side = side
        self.path = path
        self.start = start
        self.end = end
        self.commit = commit
        self.anchor = anchor
        self.commentedOn = commentedOn
        self.code = code
        self.original = original
        self.history = history
        self.comment = comment
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, review
        case shownBefore = "shown_before"
        case layer, subject, side, path, start, end, commit, anchor
        case commentedOn = "commented_on"
        case code, original, history, comment
    }
}

/// An earlier comment in a thread.
public struct HistoryComment: Codable, Sendable, Hashable {
    public var id: CommentID
    public var author: CommentAuthor
    /// Set on the agent's replies only.
    public var replyStatus: ReplyStatus?
    public var revision: Int
    public var body: String
    /// True when `body` was cut to the 300-character budget.
    public var truncated: Bool

    public init(id: CommentID, author: CommentAuthor, replyStatus: ReplyStatus?, revision: Int, body: String, truncated: Bool) {
        self.id = id
        self.author = author
        self.replyStatus = replyStatus
        self.revision = revision
        self.body = body
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case id, author
        case replyStatus = "reply_status"
        case revision, body, truncated
    }
}

/// The comment a thread waits on: `{"id":"c203","body":"…"}`.
public struct InboxComment: Codable, Sendable, Hashable {
    public var id: CommentID
    public var body: String

    public init(id: CommentID, body: String) {
        self.id = id
        self.body = body
    }
}
