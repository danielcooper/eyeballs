import Foundation

/// The version of the messages the `eyeballs` command and the app send each other.
///
/// Raise it whenever a change would stop an older command or an older app understanding a message.
public enum WireProtocol {
    public static let version = 1
}

/// Size limits on what a request and a reply may carry.
public enum WireLimits {
    /// One comment body, reply body or review note, in UTF-8 bytes.
    public static let maximumBodyBytes = 64 * 1024
    public static let maximumRepliesPerBatch = 200
    /// One request line, in bytes, newline excluded.
    public static let maximumRequestBytes = 1024 * 1024
    /// One response line. An inbox page is at most 20,000 characters of text, plus its JSON.
    public static let maximumResponseBytes = 16 * 1024 * 1024
}

/// The operation a request asks for, sent as `op`. Each `eyeballs` command sends one. It is not
/// called `Operation`, so it never clashes with Foundation's.
public struct OperationName: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let review: OperationName = "review"
    public static let wait: OperationName = "wait"
    public static let inbox: OperationName = "inbox"
    public static let show: OperationName = "show"
    public static let reply: OperationName = "reply"
    public static let threads: OperationName = "threads"
    public static let status: OperationName = "status"
    public static let attach: OperationName = "attach"
    public static let watch: OperationName = "watch"
    public static let hook: OperationName = "hook"
    public static let open: OperationName = "open"
    public static let doctor: OperationName = "doctor"
}

/// Who sent a request: the agent, its session, its Claude process and its working directory.
///
/// On the wire: `{"agent":"claude","session":"…","pid":4242,"pid_start":1760620000,"ancestors":[…],"cwd":"…"}`.
public struct ClientIdentity: Codable, Sendable, Hashable {
    /// `claude`, `codex`, or what `--agent` says. `other` when nothing identifies the agent.
    public var agent: String
    /// `CLAUDE_CODE_SESSION_ID`, `CODEX_THREAD_ID` or `--session`.
    public var session: String?
    /// `CLAUDE_PID`: the Claude Code process. It stays the same across `/clear`.
    public var pid: Int32?
    /// When `pid` started, in seconds since 1970, so a reused PID never looks alive.
    public var pidStart: Int64?
    /// The command's parent, grandparent and so on, nearest first.
    public var ancestors: [Int32]
    public var cwd: String

    public init(agent: String, session: String?, pid: Int32?, pidStart: Int64?, ancestors: [Int32], cwd: String) {
        self.agent = agent
        self.session = session
        self.pid = pid
        self.pidStart = pidStart
        self.ancestors = ancestors
        self.cwd = cwd
    }

    /// The Claude process this request came from, when the environment named one.
    public var claudeProcess: ClaudeProcess? {
        guard let pid, let pidStart else { return nil }
        return ClaudeProcess(pid: pid, start: pidStart)
    }

    enum CodingKeys: String, CodingKey {
        case agent, session, pid
        case pidStart = "pid_start"
        case ancestors, cwd
    }
}

/// One Claude Code process: its PID plus its start time. A subagent shares its parent's.
public struct ClaudeProcess: Codable, Sendable, Hashable {
    public var pid: Int32
    public var start: Int64

    public init(pid: Int32, start: Int64) {
        self.pid = pid
        self.start = start
    }
}

/// Which `wait` and `watch` connections an event goes to.
///
/// Claude Code sessions are keyed by their Claude process, so a subagent's `wait` and
/// the main session's monitor both wake. Other agents, such as a test script, are keyed by
/// their session.
public enum ListenerKey: Hashable, Sendable {
    case claudeProcess(ClaudeProcess)
    case session(agent: String, session: String)

    /// The key for a client's own connections, or nil when nothing identifies it.
    public init?(client: ClientIdentity) {
        if let process = client.claudeProcess {
            self = .claudeProcess(process)
        } else if let session = client.session {
            self = .session(agent: client.agent, session: session)
        } else {
            return nil
        }
    }
}

/// Arguments that check themselves after decoding. `Request.decodeArguments(_:)` calls
/// `validate()`, so the app never sees arguments past the size limits.
public protocol ValidatedArguments {
    /// Throws a `bad_input` `EyeballsError`.
    func validate() throws
}

/// One request line: `{"v":1,"id":7,"op":"inbox","client":{…},"args":{…}}`.
public struct Request: Sendable, Hashable {
    public var version: Int
    public var id: Int
    public var operation: OperationName
    public var client: ClientIdentity
    public var arguments: JSONValue

    public init(id: Int = 1, operation: OperationName, client: ClientIdentity, arguments: some Encodable) throws {
        self.version = WireProtocol.version
        self.id = id
        self.operation = operation
        self.client = client
        self.arguments = try JSONValue(encoding: arguments)
    }

    init(version: Int, id: Int, operation: OperationName, client: ClientIdentity, arguments: JSONValue) {
        self.version = version
        self.id = id
        self.operation = operation
        self.client = client
        self.arguments = arguments
    }

    /// The arguments as `type`. Throws a `bad_input` `EyeballsError` when they do not fit, or
    /// when `validate()` fails.
    public func decodeArguments<Arguments: Decodable>(_ type: Arguments.Type) throws -> Arguments {
        let arguments: Arguments
        do {
            arguments = try self.arguments.decode(type)
        } catch {
            throw EyeballsError.badInput(
                "The request's arguments are not in the shape this operation expects.",
                hint: "Check that the eyeballs command and the app are the same version.")
        }
        if let validated = arguments as? any ValidatedArguments {
            try validated.validate()
        }
        return arguments
    }

    /// The request as JSON, ending in a newline.
    public func line() throws -> Data {
        var object = JSONObject()
        object["v"] = .integer(Int64(version))
        object["id"] = .integer(Int64(id))
        object["op"] = .string(operation.rawValue)
        object["client"] = try JSONValue(encoding: client)
        object["args"] = arguments
        return Data((JSONValue.object(object).serialized() + "\n").utf8)
    }

    /// Reads one request line. Checks the protocol version before anything else, so a newer
    /// command always gets `version_mismatch` rather than a confusing shape error.
    public static func decode(line: some Collection<UInt8>) throws(RequestRejection) -> Request {
        guard let value = try? JSONValue(parsing: line), case .object(let object) = value else {
            throw RequestRejection(id: 0, error: .badInput("The request is not a JSON object on one line."))
        }
        let id = object["id"]?.integerValue.map { Int($0) } ?? 0
        guard let version = object["v"]?.integerValue else {
            throw RequestRejection(id: id, error: .badInput("The request has no protocol version in v."))
        }
        guard version == WireProtocol.version else {
            throw RequestRejection(id: id, error: EyeballsError(
                .versionMismatch,
                "This eyeballs command speaks protocol \(version), but the app speaks protocol \(WireProtocol.version).",
                hint: "Update Eyeballs.app or the eyeballs plugin so both are the same version."))
        }
        guard object["id"]?.integerValue != nil else {
            throw RequestRejection(id: id, error: .badInput("The request has no whole-number id."))
        }
        guard let operation = object["op"]?.stringValue, !operation.isEmpty else {
            throw RequestRejection(id: id, error: .badInput("The request has no operation in op."))
        }
        guard let client = try? object["client"]?.decode(ClientIdentity.self) else {
            throw RequestRejection(id: id, error: .badInput("The request's client block is not in the expected shape."))
        }
        let arguments = object["args"] ?? .object(JSONObject())
        guard arguments.objectValue != nil else {
            throw RequestRejection(id: id, error: .badInput("The request's args must be a JSON object."))
        }
        return Request(version: Int(version), id: id, operation: OperationName(rawValue: operation), client: client, arguments: arguments)
    }
}

/// Why the server answered a request line itself, without asking the app.
public struct RequestRejection: Error, Sendable {
    public var id: Int
    public var error: EyeballsError
}

/// One response line. Success is `{"id":7,"ok":true,"result":{…},"text":"…"}`, and failure is
/// `{"id":7,"ok":false,"error":{"code":"…","message":"…","hint":"…"}}`.
///
/// The command prints `text` by default and `result` with `--json`.
public struct Response: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case success(result: JSONValue, text: String)
        case failure(EyeballsError)

        /// Encodes `result`, keeping the order of its keys.
        public static func success(_ result: some Encodable, text: String) throws -> Outcome {
            .success(result: try JSONValue(encoding: result), text: text)
        }
    }

    public var id: Int
    public var outcome: Outcome

    public init(id: Int, outcome: Outcome) {
        self.id = id
        self.outcome = outcome
    }

    /// The response as JSON, ending in a newline.
    public func line() -> Data {
        var object = JSONObject()
        object["id"] = .integer(Int64(id))
        switch outcome {
        case .success(let result, let text):
            object["ok"] = .bool(true)
            object["result"] = result
            object["text"] = .string(text)
        case .failure(let error):
            object["ok"] = .bool(false)
            var body = JSONObject()
            body["code"] = .string(error.code.rawValue)
            body["message"] = .string(error.message)
            body["hint"] = error.hint.map(JSONValue.string) ?? .null
            body["retry_after_s"] = error.retryAfterSeconds.map { .integer(Int64($0)) } ?? .null
            object["error"] = .object(body)
        }
        return Data((JSONValue.object(object).serialized() + "\n").utf8)
    }

    /// Reads one response line. Throws an `internal` `EyeballsError` when it is not in the shape above.
    public init(line: some Collection<UInt8>) throws {
        let shapeError = EyeballsError(
            .internalError,
            "Eyeballs sent a response in a shape this command cannot read.",
            hint: "Run eyeballs doctor to check that the app and the command are the same version.")
        guard let value = try? JSONValue(parsing: line), case .object(let object) = value,
              let ok = object["ok"]?.boolValue else { throw shapeError }
        id = object["id"]?.integerValue.map { Int($0) } ?? 0
        if ok {
            outcome = .success(result: object["result"] ?? .null, text: object["text"]?.stringValue ?? "")
        } else {
            guard let error = try? object["error"]?.decode(EyeballsError.self) else { throw shapeError }
            outcome = .failure(error)
        }
    }
}

/// An event the app sends to live `wait` and `watch` connections.
///
/// Each connection receives it as a success response carrying that connection's request id.
public struct StreamEvent: Sendable, Hashable {
    public var result: JSONValue
    /// One line of at most 200 characters, such as `eyeballs: Alex submitted review 7 …`.
    public var text: String
    /// The stack it is about. A connection waiting on one stack skips events about others.
    public var stack: StackID?

    public init(result: JSONValue, text: String, stack: StackID?) {
        self.result = result
        self.text = text
        self.stack = stack
    }

    public init(_ result: some Encodable, text: String, stack: StackID?) throws {
        self.init(result: try JSONValue(encoding: result), text: text, stack: stack)
    }
}
