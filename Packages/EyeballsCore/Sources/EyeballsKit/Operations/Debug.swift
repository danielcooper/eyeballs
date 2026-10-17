extension OperationName {
    /// Debug builds only: plays the reviewer, so a script can run the whole loop without a window.
    public static let debugSubmitReview: OperationName = "debug.submitReview"
}

/// `eyeballs debug-submit-review`, in Debug builds only: adds one comment and submits it, as
/// you would in the window.
///
/// The comment goes on `line` to `endLine` of `path`, in the layer whose diff holds that file,
/// or replies to `thread` when it is set. Without `sendNow` it joins the draft review, which is
/// then submitted with `verdict` and `summary`.
public struct DebugSubmitReviewArguments: Codable, Sendable, Hashable, ValidatedArguments {
    public var stack: StackReference?
    /// Reply to this thread instead of opening a new one.
    public var thread: ThreadID?
    public var path: String?
    public var line: Int?
    public var endLine: Int?
    public var side: DiffSide
    public var body: String
    public var verdict: Verdict
    public var summary: String
    /// Send the comment at once, as Send now does, instead of submitting a review.
    public var sendNow: Bool

    public init(stack: StackReference? = nil, thread: ThreadID? = nil, path: String? = nil, line: Int? = nil, endLine: Int? = nil,
                side: DiffSide = .head, body: String, verdict: Verdict = .changesRequested, summary: String = "", sendNow: Bool = false) {
        self.stack = stack
        self.thread = thread
        self.path = path
        self.line = line
        self.endLine = endLine
        self.side = side
        self.body = body
        self.verdict = verdict
        self.summary = summary
        self.sendNow = sendNow
    }

    public func validate() throws {
        try BodyLimits.check(body, what: "The comment")
        if thread == nil, path == nil {
            throw EyeballsError.badInput("Name a file with --path, or a thread to reply to with --thread.")
        }
        if let line, line < 1 { throw EyeballsError.badInput("--line must be 1 or more.") }
        if let line, let endLine, endLine < line { throw EyeballsError.badInput("--end-line must not come before --line.") }
    }

    enum CodingKeys: String, CodingKey {
        case stack, thread, path, line
        case endLine = "end_line"
        case side, body, verdict, summary
        case sendNow = "send_now"
    }
}

/// What `debug-submit-review` returns.
public struct DebugSubmitReviewResult: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.debug-submit-review/1"
    public private(set) var ok = true
    public var stack: StackID
    /// Nil when the comment was sent on its own.
    public var review: Int?
    public var thread: ThreadID
    public var comment: CommentID

    public init(stack: StackID, review: Int?, thread: ThreadID, comment: CommentID) {
        self.stack = stack
        self.review = review
        self.thread = thread
        self.comment = comment
    }
}

extension OperationName {
    /// Debug builds only: draws the main window into a PNG, so a script can check what it shows.
    public static let debugSnapshotWindow: OperationName = "debug.snapshotWindow"
}

/// `eyeballs debug-snapshot-window --to PATH`, in Debug builds only.
public struct DebugSnapshotWindowArguments: Codable, Sendable, Hashable, ValidatedArguments {
    /// An absolute path for the PNG.
    public var path: String

    public init(path: String) {
        self.path = path
    }

    public func validate() throws {
        guard path.hasPrefix("/"), path.hasSuffix(".png") else { throw EyeballsError.badInput("--to must be an absolute path ending in .png.") }
    }
}
