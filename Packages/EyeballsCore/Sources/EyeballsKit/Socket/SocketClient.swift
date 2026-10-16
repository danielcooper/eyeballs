import Darwin
import Foundation

/// One connection to the app's socket, for the `eyeballs` command.
///
/// Every call blocks until it finishes or its timeout passes. A nil timeout waits forever,
/// which `wait` and `watch` use. Throws `SocketClientError`.
public final class SocketClient {
    /// Connects to the socket at `socket`. Throws `.notRunning` when nothing listens there.
    public static func connect(to socket: URL, timeout: Duration) throws -> SocketClient {
        let address: sockaddr_un
        do {
            address = try UnixSocket.address(for: socket.path)
        } catch {
            throw SocketClientError.pathTooLong(bytes: error.bytes)
        }
        let fd: Int32
        do {
            fd = try UnixSocket.makeStreamSocket()
        } catch {
            throw SocketClientError.system(error)
        }
        let client = SocketClient(fd: fd)
        try client.finishConnecting(to: address, timeout: timeout)
        return client
    }

    /// Sends one request, then reads its response.
    ///
    /// When the app closes the connection while the request is still going out, as it does
    /// for a request over the size limit, this still returns the error the app sent first.
    public func exchange(_ request: Request, timeout: Duration?) throws -> Response {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        do {
            try send(request, timeout: timeout)
        } catch SocketClientError.closedBeforeResponse {
            return try receive(timeout: .seconds(1))
        }
        return try receive(until: deadline, timeout: timeout)
    }

    /// Sends one request line. Throws `.requestTooLarge` for a request over 1 MB, before
    /// sending anything.
    public func send(_ request: Request, timeout: Duration?) throws {
        let line: Data
        do {
            line = try request.line()
        } catch {
            throw SocketClientError.malformedRequest
        }
        guard line.count - 1 <= WireLimits.maximumRequestBytes else {
            throw SocketClientError.requestTooLarge(bytes: line.count - 1)
        }
        try send(line: line, timeout: timeout)
    }

    /// Sends bytes as they are, with no size check.
    public func send(line: Data, timeout: Duration?) throws {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        var offset = 0
        while offset < line.count {
            let written = line.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                guard try waitFor(Int16(POLLOUT), until: deadline) else {
                    throw SocketClientError.timedOut(seconds: timeout?.wholeSecondsRoundedUp)
                }
            case EPIPE, ECONNRESET:
                throw SocketClientError.closedBeforeResponse
            default:
                throw SocketClientError.system(SystemCallError("write"))
            }
        }
    }

    /// Reads the next response line. Throws `.closedBeforeResponse` when the app closes the
    /// connection first, and `.timedOut` when `timeout` passes.
    public func receive(timeout: Duration?) throws -> Response {
        try receive(until: timeout.map { ContinuousClock.now + $0 }, timeout: timeout)
    }

    /// Closes the connection. The app still reads what was already sent.
    public func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit {
        close()
    }

    private var fd: Int32
    private var buffer: [UInt8] = []

    private init(fd: Int32) {
        self.fd = fd
    }

    private func finishConnecting(to address: sockaddr_un, timeout: Duration) throws {
        if UnixSocket.connect(fd, to: address) == 0 { return }
        let code = errno
        guard code == EINPROGRESS || code == EAGAIN || code == EINTR else {
            throw SocketClientError(connectErrno: code)
        }
        guard try waitFor(Int16(POLLOUT), until: ContinuousClock.now + timeout) else {
            throw SocketClientError.timedOut(seconds: timeout.wholeSecondsRoundedUp)
        }
        var pending: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &length) == 0 else {
            throw SocketClientError.system(SystemCallError("getsockopt"))
        }
        if pending != 0 { throw SocketClientError(connectErrno: pending) }
    }

    private func receive(until deadline: ContinuousClock.Instant?, timeout: Duration? = nil) throws -> Response {
        let line = try readLine(until: deadline, timeout: timeout)
        do {
            return try Response(line: line)
        } catch {
            throw SocketClientError.malformedResponse
        }
    }

    private func readLine(until deadline: ContinuousClock.Instant?, timeout: Duration?) throws -> [UInt8] {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var alreadySearched = 0
        while true {
            if let newline = buffer[alreadySearched...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            alreadySearched = buffer.count
            guard buffer.count <= WireLimits.maximumResponseBytes else { throw SocketClientError.responseTooLarge }
            guard try waitFor(Int16(POLLIN), until: deadline) else {
                throw SocketClientError.timedOut(seconds: (timeout ?? deadline.map { ContinuousClock.now.duration(to: $0) })?.wholeSecondsRoundedUp)
            }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[..<count])
            } else if count == 0 {
                throw SocketClientError.closedBeforeResponse
            } else if errno == ECONNRESET {
                throw SocketClientError.closedBeforeResponse
            } else if errno != EINTR && errno != EAGAIN {
                throw SocketClientError.system(SystemCallError("read"))
            }
        }
    }

    private func waitFor(_ events: Int16, until deadline: ContinuousClock.Instant?) throws -> Bool {
        guard fd >= 0 else { throw SocketClientError.closedBeforeResponse }
        do {
            return try UnixSocket.wait(fd, for: events, until: deadline)
        } catch {
            throw SocketClientError.system(error)
        }
    }
}

/// Why the command could not talk to the app.
public enum SocketClientError: Error, Sendable, Hashable {
    /// No socket file, or nothing listening on it.
    case notRunning
    /// The socket path does not fit in the 103 bytes macOS allows.
    case pathTooLong(bytes: Int)
    /// Claude Code's sandbox, or another rule, refused the connection.
    case blocked
    /// The socket belongs to someone else.
    case permissionDenied
    case timedOut(seconds: Int64?)
    /// The app closed the connection before it answered, for example because it quit.
    case closedBeforeResponse
    case malformedResponse
    case malformedRequest
    case responseTooLarge
    case requestTooLarge(bytes: Int)
    case system(SystemCallError)

    init(connectErrno code: Int32) {
        switch code {
        case ENOENT, ECONNREFUSED, ENOTDIR: self = .notRunning
        case EPERM: self = .blocked
        case EACCES: self = .permissionDenied
        default: self = .system(SystemCallError("connect", code: code))
        }
    }

    /// The error the command reports, with its code and exit status.
    public var eyeballsError: EyeballsError {
        switch self {
        case .notRunning:
            EyeballsError(.appUnavailable, "Eyeballs is not running.", hint: "Open Eyeballs, then try again.")
        case .pathTooLong(let bytes):
            EyeballsError(.appUnavailable, "The socket path is \(bytes) bytes, over the \(UnixSocket.maximumPathBytes)-byte limit macOS allows.",
                          hint: "Set EYEBALLS_HOME to a shorter folder.")
        case .blocked:
            EyeballsError(.sandboxBlocked, "The sandbox blocked the connection to Eyeballs.",
                          hint: "Add the socket to sandbox.network.allowUnixSockets. Run eyeballs doctor for the exact setting.")
        case .permissionDenied:
            EyeballsError(.appUnavailable, "This user cannot open the Eyeballs socket.", hint: "Run eyeballs doctor to check the folder's owner.")
        case .timedOut(let seconds):
            EyeballsError(.appUnavailable, seconds.map { "Eyeballs did not answer within \($0) s." } ?? "Eyeballs did not answer.",
                          hint: "Check that Eyeballs is responding, then try again.", retryAfterSeconds: 10)
        case .closedBeforeResponse:
            EyeballsError(.appUnavailable, "Eyeballs closed the connection before it answered.", hint: "Check that Eyeballs is still running, then try again.")
        case .malformedResponse, .responseTooLarge:
            EyeballsError(.internalError, "Eyeballs sent a response this command cannot read.",
                          hint: "Run eyeballs doctor to check that the app and the command are the same version.")
        case .malformedRequest:
            EyeballsError(.internalError, "This command could not encode its request.", hint: "Tell the reviewer, quoting this line.")
        case .requestTooLarge(let bytes):
            EyeballsError(.badInput, "The request is \(bytes / 1024) KB, over the \(WireLimits.maximumRequestBytes / 1024) KB limit.",
                          hint: "Send fewer or shorter replies at a time.")
        case .system(let error):
            EyeballsError(.internalError, "Talking to Eyeballs failed: \(error.description).", hint: "Tell the reviewer, quoting this line.")
        }
    }
}
