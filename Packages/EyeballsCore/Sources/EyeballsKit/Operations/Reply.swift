/// `eyeballs reply`: the agent answers one or many threads in one call.
///
/// The app checks every thread before it saves any reply, so an unknown thread fails the whole
/// batch with `unknown_thread` and nothing is posted.
public struct ReplyArguments: Codable, Sendable, Hashable, ValidatedArguments {
    public var replies: [ReplyItem]

    public init(replies: [ReplyItem]) {
        self.replies = replies
    }

    public func validate() throws {
        guard !replies.isEmpty else {
            throw EyeballsError.badInput("The reply batch has no replies.", hint: "Start each reply with a line such as ## t41 addressed.")
        }
        guard replies.count <= WireLimits.maximumRepliesPerBatch else {
            throw EyeballsError.badInput(
                "The reply batch has \(replies.count) replies, over the limit of \(WireLimits.maximumRepliesPerBatch).",
                hint: "Split it into smaller batches.")
        }
        var seen = Set<ThreadID>()
        for reply in replies {
            guard seen.insert(reply.thread).inserted else {
                throw EyeballsError.badInput("The batch replies to \(reply.thread) twice.", hint: "Join the two replies into one block.")
            }
            try reply.validate()
        }
    }
}

/// One reply: `{"thread":"t42","status":"addressed","body":"…","at":[{"path":"…","start":40,"end":58}]}`.
public struct ReplyItem: Codable, Sendable, Hashable {
    public var thread: ThreadID
    public var status: ReplyStatus
    public var body: String
    /// Where the fix is, when it is not on the commented lines.
    public var at: [LineSpan]

    public init(thread: ThreadID, status: ReplyStatus, body: String, at: [LineSpan] = []) {
        self.thread = thread
        self.status = status
        self.body = body
        self.at = at
    }

    func validate() throws {
        guard !body.allSatisfy(\.isWhitespace) else {
            throw EyeballsError.badInput("The reply to \(thread) has no text.", hint: "Say what you changed, or why not.")
        }
        try BodyLimits.check(body, what: "The reply to \(thread)")
        for span in at {
            if let problem = span.problem {
                throw EyeballsError.badInput("An at: range in the reply to \(thread) \(problem).")
            }
        }
    }
}

/// What `eyeballs reply` returns.
public struct ReplyResult: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.reply/1"
    public private(set) var ok = true
    public var replied: [RepliedThread]
    /// Threads that still wait on the agent after this batch.
    public var waitingOnYou: [ThreadID]
    /// Can hold `not_driver` and `thread_resolved`.
    public var warnings: [Warning]
    public var next: NextStep

    public init(replied: [RepliedThread], waitingOnYou: [ThreadID], warnings: [Warning], next: NextStep) {
        self.replied = replied
        self.waitingOnYou = waitingOnYou
        self.warnings = warnings
        self.next = next
    }

    enum CodingKeys: String, CodingKey {
        case schema, ok, replied
        case waitingOnYou = "waiting_on_you"
        case warnings, next
    }
}

/// `{"thread":"t41","status":"addressed","comment":"c210"}`.
public struct RepliedThread: Codable, Sendable, Hashable {
    public var thread: ThreadID
    public var status: ReplyStatus
    public var comment: CommentID

    public init(thread: ThreadID, status: ReplyStatus, comment: CommentID) {
        self.thread = thread
        self.status = status
        self.comment = comment
    }
}
