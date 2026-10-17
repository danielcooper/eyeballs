/// `eyeballs open [PATH]`: you open a repo in the window.
public struct OpenArguments: Codable, Sendable, Hashable, ValidatedArguments {
    /// An absolute path. The command resolves a relative one against its working directory.
    /// Nil means "show the stack I am working on", which never adds a stack.
    public var path: String?

    public init(path: String?) {
        self.path = path
    }

    public func validate() throws {
        guard path?.hasPrefix("/") ?? true else { throw EyeballsError.badInput("The path to open must be absolute.") }
    }
}

/// What `eyeballs open` returns.
public struct OpenResult: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.open/1"
    public private(set) var ok = true
    /// The repo's top-level folder.
    public var repo: String
    public var stacks: [StackSummary]

    public init(repo: String, stacks: [StackSummary]) {
        self.repo = repo
        self.stacks = stacks
    }
}
