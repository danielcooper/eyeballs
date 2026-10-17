/// `eyeballs threads`: one line per thread.
public struct ThreadsArguments: Codable, Sendable, Hashable {
    public var filter: ThreadFilter

    public init(filter: ThreadFilter = .open) {
        self.filter = filter
    }
}

public struct ThreadFilter: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let open: ThreadFilter = "open"
    public static let all: ThreadFilter = "all"
}

/// What `eyeballs threads` returns.
public struct ThreadsResult: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.threads/1"
    public private(set) var ok = true
    public var threads: [ThreadLine]

    public init(threads: [ThreadLine]) {
        self.threads = threads
    }
}

/// One thread, as in `t42  api-client  Sources/API/Client.swift:40-44  waiting on Alex (you: addressed)`.
public struct ThreadLine: Codable, Sendable, Hashable {
    public var id: ThreadID
    public var stack: StackID
    public var layer: ThreadLayer
    public var path: String?
    public var start: Int?
    public var end: Int?
    public var status: ThreadStatus
    /// Who has to act next.
    public var waitingOn: WaitingOn
    /// The derived state in words, such as "Check the fix".
    public var state: String
    /// The agent's newest reply status on this thread, if any.
    public var lastReply: ReplyStatus?

    public init(id: ThreadID, stack: StackID, layer: ThreadLayer, path: String?, start: Int?, end: Int?, status: ThreadStatus,
                waitingOn: WaitingOn, state: String, lastReply: ReplyStatus?) {
        self.id = id
        self.stack = stack
        self.layer = layer
        self.path = path
        self.start = start
        self.end = end
        self.status = status
        self.waitingOn = waitingOn
        self.state = state
        self.lastReply = lastReply
    }

    enum CodingKeys: String, CodingKey {
        case id, stack, layer, path, start, end, status
        case waitingOn = "waiting_on"
        case state
        case lastReply = "last_reply"
    }
}

public struct WaitingOn: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let agent: WaitingOn = "agent"
    public static let reviewer: WaitingOn = "reviewer"
    public static let nobody: WaitingOn = "nobody"
}
