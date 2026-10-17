/// `eyeballs show tN`: one thread in full, with its code and anchor history.
public struct ShowArguments: Codable, Sendable, Hashable, ValidatedArguments {
    public var thread: ThreadID
    /// Lines of context around the covered lines. Nil means the app's default of 5.
    public var context: Int?

    public init(thread: ThreadID, context: Int? = nil) {
        self.thread = thread
        self.context = context
    }

    public func validate() throws {
        if let context, !(0...100).contains(context) {
            throw EyeballsError.badInput("--context must be between 0 and 100 lines.")
        }
    }
}

/// What `eyeballs show` returns.
public struct ShowResult: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.show/1"
    public private(set) var ok = true
    public var stack: StackSummary
    public var thread: ShownThread

    public init(stack: StackSummary, thread: ShownThread) {
        self.stack = stack
        self.thread = thread
    }
}

public struct ShownThread: Codable, Sendable, Hashable {
    public var id: ThreadID
    public var status: ThreadStatus
    /// The derived state in words, such as "Waiting on agent" or "Check the fix".
    public var state: String
    public var subject: ThreadSubject
    public var side: DiffSide?
    public var layer: ThreadLayer
    public var path: String?
    public var start: Int?
    public var end: Int?
    public var commit: String?
    public var anchor: AnchorState
    /// The newest revision, whose code `code` shows.
    public var revision: Int
    /// The covered lines plus the context lines around them.
    public var code: [CodeLine]
    public var original: [String]?
    /// Every comment, in full, oldest first.
    public var comments: [ShownComment]
    /// Where the thread sat at each revision, such as `r3 40-44 original` then `r4 40-44 current`.
    public var anchors: [AnchorStep]

    public init(id: ThreadID, status: ThreadStatus, state: String, subject: ThreadSubject, side: DiffSide?, layer: ThreadLayer,
                path: String?, start: Int?, end: Int?, commit: String?, anchor: AnchorState, revision: Int, code: [CodeLine],
                original: [String]?, comments: [ShownComment], anchors: [AnchorStep]) {
        self.id = id
        self.status = status
        self.state = state
        self.subject = subject
        self.side = side
        self.layer = layer
        self.path = path
        self.start = start
        self.end = end
        self.commit = commit
        self.anchor = anchor
        self.revision = revision
        self.code = code
        self.original = original
        self.comments = comments
        self.anchors = anchors
    }
}

public struct CodeLine: Codable, Sendable, Hashable {
    public var line: Int
    public var text: String
    /// True for the lines the thread is on, false for context.
    public var covered: Bool

    public init(line: Int, text: String, covered: Bool) {
        self.line = line
        self.text = text
        self.covered = covered
    }
}

public struct ShownComment: Codable, Sendable, Hashable {
    public var id: CommentID
    public var author: CommentAuthor
    /// The reviewer's name, or the agent's.
    public var name: String
    public var replyStatus: ReplyStatus?
    public var revision: Int
    public var body: String
    /// The agent's `at:` lines.
    public var at: [LineSpan]
    /// ISO 8601, UTC.
    public var createdAt: String

    public init(id: CommentID, author: CommentAuthor, name: String, replyStatus: ReplyStatus?, revision: Int,
                body: String, at: [LineSpan], createdAt: String) {
        self.id = id
        self.author = author
        self.name = name
        self.replyStatus = replyStatus
        self.revision = revision
        self.body = body
        self.at = at
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, author, name
        case replyStatus = "reply_status"
        case revision, body, at
        case createdAt = "created_at"
    }
}

public struct AnchorStep: Codable, Sendable, Hashable {
    public var revision: Int
    public var start: Int?
    public var end: Int?
    public var state: AnchorState

    public init(revision: Int, start: Int?, end: Int?, state: AnchorState) {
        self.revision = revision
        self.start = start
        self.end = end
        self.state = state
    }
}
