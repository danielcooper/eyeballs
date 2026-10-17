/// `eyeballs status`: one status line for the agent, the skill and hooks. It always exits 0.
public struct StatusArguments: Codable, Sendable, Hashable {
    /// Ask for one line, such as `Eyeballs: you drive checkout-v2 (s3) at r4. …`.
    public var brief: Bool

    public init(brief: Bool = false) {
        self.brief = brief
    }
}

/// What `eyeballs status` returns. The command builds one itself when the app is not running.
public struct StatusResult: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.status/1"
    public private(set) var ok = true
    public var app: AppState
    /// The stacks this session drives or has touched.
    public var stacks: [StatusStack]
    /// What this session's Claude process has connected.
    public var listening: [Listener]

    public init(app: AppState, stacks: [StatusStack] = [], listening: [Listener] = []) {
        self.app = app
        self.stacks = stacks
        self.listening = listening
    }

    /// The result and text the command prints when the socket does not answer.
    public static let notRunning = StatusResult(app: .notRunning)
    public static let notRunningText = "Eyeballs: app not running."
}

public struct AppState: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let running: AppState = "running"
    public static let notRunning: AppState = "not_running"
}

public struct StatusStack: Codable, Sendable, Hashable {
    public var stack: StackSummary
    public var revision: Int?
    /// True when the calling session drives this stack.
    public var driver: Bool
    /// The newest submitted review.
    public var review: Int?
    /// Threads that `inbox` showed and that still have no reply.
    public var needsReply: [ThreadID]
    public var waitingOnReviewer: Int

    public init(stack: StackSummary, revision: Int?, driver: Bool, review: Int?, needsReply: [ThreadID], waitingOnReviewer: Int) {
        self.stack = stack
        self.revision = revision
        self.driver = driver
        self.review = review
        self.needsReply = needsReply
        self.waitingOnReviewer = waitingOnReviewer
    }

    enum CodingKeys: String, CodingKey {
        case stack, revision, driver, review
        case needsReply = "needs_reply"
        case waitingOnReviewer = "waiting_on_reviewer"
    }
}
