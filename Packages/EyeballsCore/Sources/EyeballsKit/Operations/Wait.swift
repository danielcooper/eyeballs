/// `eyeballs wait`: the driver runs it in the background, and it returns when something needs
/// the agent.
///
/// The app answers at once when something is already waiting, and otherwise streams one event
/// and closes the connection.
public struct WaitArguments: Codable, Sendable, Hashable, ValidatedArguments {
    public var stack: StackReference?
    /// Nil waits forever.
    public var timeoutSeconds: Int?

    public init(stack: StackReference? = nil, timeoutSeconds: Int? = nil) {
        self.stack = stack
        self.timeoutSeconds = timeoutSeconds
    }

    public func validate() throws {
        if let timeoutSeconds, timeoutSeconds <= 0 {
            throw EyeballsError.badInput("The wait timeout must be longer than 0 seconds.")
        }
    }

    enum CodingKeys: String, CodingKey {
        case stack
        case timeoutSeconds = "timeout_s"
    }
}

/// `eyeballs watch`: the plugin monitor's stream. It takes no arguments; the client block says
/// which Claude process it belongs to.
public struct WatchArguments: Codable, Sendable, Hashable {
    public init() {}
}

/// One event for `wait` and `watch`:
/// `{"schema":"eyeballs.wait/1","ok":true,"event":"review.submitted","stack":"s3","review":7,"threads":5,"verdict":"changes_requested","next":"run_inbox"}`.
///
/// The response's `text` carries the one-line form, such as
/// `eyeballs: Alex submitted review 7 on checkout-v2 (s3, r4): 5 threads, changes requested. Run: eyeballs inbox`.
public struct WaitEvent: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.wait/1"
    public private(set) var ok = true
    public var event: WaitEventKind
    public var stack: StackID?
    public var review: Int?
    public var threads: Int?
    public var verdict: Verdict?
    public var next: NextStep

    public init(event: WaitEventKind, stack: StackID?, review: Int? = nil, threads: Int? = nil,
                verdict: Verdict? = nil, next: NextStep = .runInbox) {
        self.event = event
        self.stack = stack
        self.review = review
        self.threads = threads
        self.verdict = verdict
        self.next = next
    }
}

extension WaitEvent {
    /// The event `wait` reports when its timeout passes with nothing new. The agent then runs
    /// `eyeballs inbox`, and waits again in an unattended run.
    public static func timeoutEvent(after duration: Duration, stack: StackID?) -> StreamEvent {
        let event = WaitEvent(event: .timeout, stack: stack, next: .runInbox)
        let text = "eyeballs: Nothing arrived within \(DurationText.format(duration)). Run: eyeballs inbox"
        // Encoding cannot fail: WaitEvent holds only strings, integers and booleans.
        return (try? StreamEvent(event, text: text, stack: stack)) ?? StreamEvent(result: .null, text: text, stack: stack)
    }
}

public struct WaitEventKind: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let reviewSubmitted: WaitEventKind = "review.submitted"
    public static let commentSent: WaitEventKind = "comment.sent"
    public static let reviewApproved: WaitEventKind = "review.approved"
    public static let stackClosed: WaitEventKind = "stack.closed"
    /// Another session took the driver role.
    public static let rebound: WaitEventKind = "rebound"
    /// A live session other than the caller drives the stack.
    public static let notDriver: WaitEventKind = "not_driver"
    public static let timeout: WaitEventKind = "timeout"
}

/// Joins the lines of events that arrive close together into one monitor line.
///
/// Claude Code turns each line a monitor prints into a notification, so `watch` merges events
/// that arrive within 3 s. The newest line wins, because every event says to run
/// `eyeballs inbox`, and `inbox` returns everything that waits.
public enum WatchLine {
    public static let mergeWindow: Duration = .seconds(3)

    public static func merge(_ lines: [String]) -> String {
        guard let newest = lines.last else { return "" }
        let single = limited(newest)
        guard lines.count > 1 else { return single }
        let prefix = "eyeballs: "
        let body = newest.hasPrefix(prefix) ? String(newest.dropFirst(prefix.count)) : newest
        let merged = "\(prefix)\(lines.count) updates. Latest: \(body)"
        return merged.count <= TextBudget.eventLine ? merged : single
    }

    /// Cuts a line to the 200-character budget and keeps it on one line.
    static func limited(_ line: String) -> String {
        let flat = line.replacingNewlines()
        guard flat.count > TextBudget.eventLine else { return flat }
        return String(flat.prefix(TextBudget.eventLine - 1)) + "…"
    }
}

extension String {
    func replacingNewlines() -> String {
        String(map { $0.isNewline ? " " : $0 })
    }
}
