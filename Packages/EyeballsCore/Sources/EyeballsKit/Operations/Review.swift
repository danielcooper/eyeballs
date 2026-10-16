/// `eyeballs review`: the driver submits a new revision and the window opens.
public struct ReviewArguments: Codable, Sendable, Hashable, ValidatedArguments {
    /// `--stack sN`, or any branch in the stack.
    public var stack: StackReference?
    /// `--branch B`: review one branch.
    public var branch: String?
    /// `--branches a,b,c`: review an explicit stack, bottom layer first.
    public var branches: [String]?
    /// `--trunk T`, with `--branch` or `--branches`.
    public var trunk: String?
    public var note: String?
    /// Take keyboard focus when the window comes to the front.
    public var focus: Bool
    /// Skip the check for threads that `inbox` showed and that have no reply yet.
    public var force: Bool

    public init(stack: StackReference? = nil, branch: String? = nil, branches: [String]? = nil, trunk: String? = nil,
                note: String? = nil, focus: Bool = false, force: Bool = false) {
        self.stack = stack
        self.branch = branch
        self.branches = branches
        self.trunk = trunk
        self.note = note
        self.focus = focus
        self.force = force
    }

    public func validate() throws {
        let choices = [stack != nil, branch != nil, branches != nil].filter { $0 }.count
        guard choices <= 1 else {
            throw EyeballsError.badInput("Name the stack one way only: --stack, --branch or --branches.")
        }
        if trunk != nil, branch == nil, branches == nil {
            throw EyeballsError.badInput("--trunk works only with --branch or --branches.")
        }
        if let branches {
            guard !branches.isEmpty, branches.allSatisfy({ !$0.isEmpty }) else {
                throw EyeballsError.badInput("--branches needs branch names separated by commas, bottom layer first.")
            }
            guard Set(branches).count == branches.count else {
                throw EyeballsError.badInput("--branches names the same branch twice.")
            }
        }
        if let note { try BodyLimits.check(note, what: "The note") }
    }

    enum CodingKeys: String, CodingKey {
        case stack, branch, branches, trunk, note, focus, force
    }
}

/// What `eyeballs review` returns.
public struct ReviewResult: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.review/1"
    public private(set) var ok = true
    public var stack: StackSummary
    /// The revision number, shown as `r4`.
    public var revision: Int
    /// False when nothing changed since the last revision, so no new one was made.
    public var created: Bool
    public var layers: [ReviewLayer]
    public var ported: PortCounts
    public var warnings: [Warning]
    /// Threads already waiting on the agent.
    public var waitingOnYou: [ThreadID]
    /// How many threads wait on the reviewer.
    public var waitingOnReviewer: Int
    /// What the driver's Claude process has connected.
    public var listening: [Listener]
    /// `run_wait_in_background`, `end_turn` or `run_inbox`.
    public var next: NextStep

    public init(stack: StackSummary, revision: Int, created: Bool, layers: [ReviewLayer], ported: PortCounts,
                warnings: [Warning], waitingOnYou: [ThreadID], waitingOnReviewer: Int, listening: [Listener], next: NextStep) {
        self.stack = stack
        self.revision = revision
        self.created = created
        self.layers = layers
        self.ported = ported
        self.warnings = warnings
        self.waitingOnYou = waitingOnYou
        self.waitingOnReviewer = waitingOnReviewer
        self.listening = listening
        self.next = next
    }

    enum CodingKeys: String, CodingKey {
        case schema, ok, stack, revision, created, layers, ported, warnings
        case waitingOnYou = "waiting_on_you"
        case waitingOnReviewer = "waiting_on_reviewer"
        case listening, next
    }
}

/// One layer in a review result.
public struct ReviewLayer: Codable, Sendable, Hashable {
    public var position: Int
    public var branch: String
    public var pr: Int?
    public var files: Int
    public var additions: Int
    public var deletions: Int
    /// `parent_tip`, `recorded_base`, `fork_point` or `merge_base`. Anything but `parent_tip` needs a restack.
    public var baseRule: String
    public var changedSinceLast: Bool

    public init(position: Int, branch: String, pr: Int?, files: Int, additions: Int, deletions: Int,
                baseRule: String, changedSinceLast: Bool) {
        self.position = position
        self.branch = branch
        self.pr = pr
        self.files = files
        self.additions = additions
        self.deletions = deletions
        self.baseRule = baseRule
        self.changedSinceLast = changedSinceLast
    }

    enum CodingKeys: String, CodingKey {
        case position, branch, pr, files, additions, deletions
        case baseRule = "base_rule"
        case changedSinceLast = "changed_since_last"
    }
}

/// How the open threads fared when they moved to the new revision.
public struct PortCounts: Codable, Sendable, Hashable {
    public var current = 0
    public var moved = 0
    public var whitespace = 0
    public var changed = 0
    public var relocated = 0
    public var outdated = 0
    public var gone = 0

    public init(current: Int = 0, moved: Int = 0, whitespace: Int = 0, changed: Int = 0,
                relocated: Int = 0, outdated: Int = 0, gone: Int = 0) {
        self.current = current
        self.moved = moved
        self.whitespace = whitespace
        self.changed = changed
        self.relocated = relocated
        self.outdated = outdated
        self.gone = gone
    }
}

/// Checks text the agent sends against the 64 KB body limit.
enum BodyLimits {
    static func check(_ text: String, what: String) throws {
        let size = text.utf8.count
        guard size <= WireLimits.maximumBodyBytes else {
            throw EyeballsError.badInput(
                "\(what) is \(size / 1024) KB, over the \(WireLimits.maximumBodyBytes / 1024) KB limit.",
                hint: "Shorten it.")
        }
    }
}
