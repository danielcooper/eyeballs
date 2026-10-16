/// `eyeballs attach`: a session takes over as the stack's driver.
public struct AttachArguments: Codable, Sendable, Hashable {
    public var stack: StackReference?

    public init(stack: StackReference? = nil) {
        self.stack = stack
    }
}

/// What `eyeballs attach` returns.
public struct AttachResult: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.attach/1"
    public private(set) var ok = true
    public var stack: StackSummary
    public var revision: Int?
    /// True when another session was driver before. Its `wait` connections end with `rebound`.
    public var tookOver: Bool
    public var next: NextStep

    public init(stack: StackSummary, revision: Int?, tookOver: Bool, next: NextStep) {
        self.stack = stack
        self.revision = revision
        self.tookOver = tookOver
        self.next = next
    }

    enum CodingKeys: String, CodingKey {
        case schema, ok, stack, revision
        case tookOver = "took_over"
        case next
    }
}
