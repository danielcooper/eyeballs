import Darwin
import Foundation

/// Answers the requests that reach the app's socket. The app implements it.
///
/// The server has already checked the caller's user ID, the size limit and the protocol
/// version. Use `request.decodeArguments(_:)` to read the arguments for `request.operation`.
public protocol RequestHandler: Sendable {
    /// Returns one response, or keeps the connection open as a stream.
    ///
    /// Answer an operation you do not know with `version_mismatch`, because only a newer
    /// command sends one. A thrown `EyeballsError` goes back to the command as it is; any other
    /// error goes back as `internal`.
    func respond(to request: Request, from peer: Peer) async throws -> HandlerOutcome
}

/// What a handler does with one request.
public enum HandlerOutcome: Sendable {
    /// Send one response line, then close the connection.
    case respond(Response.Outcome)
    /// Keep the connection open for `SocketServer.broadcast(_:to:)`.
    case stream(StreamRequest)

    public static func success(_ result: some Encodable, text: String) throws -> HandlerOutcome {
        .respond(try .success(result, text: text))
    }

    public static func failure(_ error: EyeballsError) -> HandlerOutcome {
        .respond(.failure(error))
    }
}

/// How a `wait` or `watch` connection stays open.
public struct StreamRequest: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable {
        /// One event, then the connection closes.
        case wait
        /// Events until the command disconnects.
        case watch
    }

    public var mode: Mode
    /// Whose events this connection receives.
    public var listener: ListenerKey
    /// Receive only events about this stack. Nil receives every event for the listener.
    public var stack: StackID?
    /// Sends `event` and closes the connection when nothing arrives in time. Only `wait` uses it.
    public var timeout: StreamTimeout?

    public init(mode: Mode, listener: ListenerKey, stack: StackID? = nil, timeout: StreamTimeout? = nil) {
        self.mode = mode
        self.listener = listener
        self.stack = stack
        self.timeout = timeout
    }
}

public struct StreamTimeout: Sendable, Hashable {
    public var after: Duration
    public var event: StreamEvent

    public init(after: Duration, event: StreamEvent) {
        self.after = after
        self.event = event
    }
}

/// An open `wait` or `watch` connection, for the status pill and the review result's `listening`.
public struct LiveStream: Sendable, Hashable {
    public var connection: Int
    public var mode: StreamRequest.Mode
    public var listener: ListenerKey
    public var stack: StackID?
    public var client: ClientIdentity
    public var openedAt: Date
}

/// The process on the other end of a connection, as the kernel reports it.
public struct Peer: Sendable, Hashable {
    public var userID: uid_t
    public var groupID: gid_t
    /// Nil when the kernel would not say.
    public var processID: Int32?

    public init(userID: uid_t, groupID: gid_t, processID: Int32?) {
        self.userID = userID
        self.groupID = groupID
        self.processID = processID
    }

    /// Reads the peer of a connected Unix socket with `getpeereid` and `LOCAL_PEERPID`.
    static func of(_ fd: Int32) -> Peer? {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        guard getpeereid(fd, &userID, &groupID) == 0 else { return nil }
        var processID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let known = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &processID, &length) == 0
        return Peer(userID: userID, groupID: groupID, processID: known ? processID : nil)
    }
}
