import Darwin
import Foundation

/// The app's socket: a plain BSD Unix socket in `EyeballsHome.run`.
///
/// It accepts many connections at once on dispatch sources, refuses other users with
/// `getpeereid`, caps each request at 1 MB, and hands each request to a `RequestHandler`. It
/// remembers every open `wait` and `watch` connection by its Claude process, so
/// `broadcast(_:to:)` reaches all of a driver's listeners at once (fix 10).
///
/// Network.framework's `NWListener` is not used, because it does not expose the peer's
/// credentials.
public final class SocketServer: @unchecked Sendable {
    public struct Limits: Sendable {
        public var maximumRequestBytes = WireLimits.maximumRequestBytes
        /// How long a client has to send its request line.
        public var requestTimeout: Duration = .seconds(10)

        public init() {}

        public static let standard = Limits()
    }

    public let home: EyeballsHome

    /// The live `wait` and `watch` connections, sent again whenever one opens or closes.
    /// Only the newest list is kept, so a slow reader never falls behind.
    public let liveStreamChanges: AsyncStream<[LiveStream]>

    /// `allowedUser` exists for tests. Leave it as the app's own user.
    public init(home: EyeballsHome, handler: some RequestHandler, limits: Limits = .standard, allowedUser: uid_t = geteuid()) {
        self.home = home
        self.handler = handler
        self.limits = limits
        self.allowedUser = allowedUser
        (liveStreamChanges, liveStreamContinuation) = AsyncStream.makeStream(of: [LiveStream].self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Creates the run folder (0700), binds the socket (0600) and starts listening.
    ///
    /// A socket file left by an earlier run is removed only when `holdingInstanceLock` is true,
    /// because only the process that holds `run/app.lock` can know that no other app is using it.
    /// A server listens once: after `stop()`, create a new one. Throws `SocketServerError`.
    public func start(holdingInstanceLock: Bool) throws {
        try queue.sync { try listen(holdingInstanceLock: holdingInstanceLock) }
    }

    /// Stops listening, closes every connection and removes the socket file.
    public func stop() {
        queue.sync {
            stopped = true
            listenSource?.cancel()
            listenSource = nil
            for connection in connections.values.sorted(by: { $0.id < $1.id }) { connection.close() }
            connections.removeAll()
            if let bound = boundSocket {
                var info = stat()
                if lstat(bound.path, &info) == 0, info.st_ino == bound.inode { unlink(bound.path) }
            }
            boundSocket = nil
        }
        liveStreamContinuation.yield([])
        liveStreamContinuation.finish()
    }

    /// Sends `event` to every live `wait` and `watch` connection of `listener`. A `wait`
    /// connection closes after its event; a `watch` connection stays open.
    ///
    /// Returns how many connections it reached, so the caller can tell whether anyone listened.
    @discardableResult
    public func broadcast(_ event: StreamEvent, to listener: ListenerKey) -> Int {
        queue.sync {
            var reached = 0
            for connection in connections.values.sorted(by: { $0.id < $1.id }) {
                guard case .streaming(let stream) = connection.phase, stream.request.listener == listener else { continue }
                if let wanted = stream.request.stack, let about = event.stack, wanted != about { continue }
                deliver(event, to: connection, stream: stream)
                reached += 1
            }
            return reached
        }
    }

    /// The live `wait` and `watch` connections now.
    public func liveStreams() -> [LiveStream] {
        queue.sync { currentLiveStreams() }
    }

    private let handler: any RequestHandler
    private let limits: Limits
    private let allowedUser: uid_t
    private let queue = DispatchQueue(label: "coops.eyeballs.socket-server")
    private let liveStreamContinuation: AsyncStream<[LiveStream]>.Continuation

    // Everything below is touched only on `queue`.
    private var listenSource: (any DispatchSourceRead)?
    private var connections: [Int: ServerConnection] = [:]
    private var nextConnectionID = 1
    private var boundSocket: (path: String, inode: ino_t)?
    private var stopped = false

    private func listen(holdingInstanceLock: Bool) throws {
        guard listenSource == nil, !stopped else { throw SocketServerError.alreadyStarted }
        try prepareRunFolder()

        let path = home.socket.path
        let address: sockaddr_un
        do {
            address = try UnixSocket.address(for: path)
        } catch {
            throw SocketServerError.socketPathTooLong(bytes: error.bytes)
        }
        try removeStaleSocket(at: path, holdingInstanceLock: holdingInstanceLock)

        let fd: Int32
        do {
            fd = try UnixSocket.makeStreamSocket()
        } catch {
            throw SocketServerError.system(error)
        }
        guard UnixSocket.bind(fd, to: address) == 0 else {
            let code = errno
            close(fd)
            throw code == EADDRINUSE ? SocketServerError.socketExists : SocketServerError.system(SystemCallError("bind", code: code))
        }
        var info = stat()
        var failedCall: String?
        if chmod(path, 0o600) != 0 {
            failedCall = "chmod"
        } else if lstat(path, &info) != 0 {
            failedCall = "lstat"
        } else if Darwin.listen(fd, 128) != 0 {
            failedCall = "listen"
        }
        if let failedCall {
            let error = SystemCallError(failedCall)
            close(fd)
            unlink(path)
            throw SocketServerError.system(error)
        }
        boundSocket = (path, info.st_ino)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenSource = source
    }

    /// The run folder must be a real folder, owned by this user, that no one else can enter.
    private func prepareRunFolder() throws {
        do {
            try home.prepare()
        } catch {
            throw SocketServerError.unsafeRunFolder
        }
        var info = stat()
        guard lstat(home.run.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw SocketServerError.unsafeRunFolder
        }
    }

    private func removeStaleSocket(at path: String, holdingInstanceLock: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard holdingInstanceLock else { throw SocketServerError.socketExists }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw SocketServerError.notASocket }
        guard unlink(path) == 0 else { throw SocketServerError.system(SystemCallError("unlink")) }
    }

    private func acceptConnections(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            guard (try? UnixSocket.configure(fd)) != nil,
                  let peer = Peer.of(fd), peer.userID == allowedUser else {
                close(fd)
                continue
            }
            open(fd, peer: peer)
        }
    }

    private func open(_ fd: Int32, peer: Peer) {
        let connection = ServerConnection(id: nextConnectionID, fd: fd, peer: peer, queue: queue, maximumRequestBytes: limits.maximumRequestBytes)
        nextConnectionID += 1
        connections[connection.id] = connection
        connection.onRequestLine = { [weak self] connection, line in self?.received(line, on: connection) }
        connection.onRequestTooLarge = { connection in
            connection.finish(with: Response(id: 0, outcome: .failure(.badInput(
                "The request is over the \(WireLimits.maximumRequestBytes / 1024) KB limit.",
                hint: "Send fewer or shorter replies at a time."))))
        }
        connection.onClose = { [weak self] connection in self?.closed(connection) }
        connection.start(requestTimeout: limits.requestTimeout)
    }

    private func received(_ line: [UInt8], on connection: ServerConnection) {
        let request: Request
        do {
            request = try Request.decode(line: line)
        } catch {
            connection.finish(with: Response(id: error.id, outcome: .failure(error.error)))
            return
        }
        let connectionID = connection.id
        let peer = connection.peer
        Task { [handler] in
            let outcome: HandlerOutcome
            do {
                outcome = try await handler.respond(to: request, from: peer)
            } catch {
                outcome = .failure(EyeballsError(error))
            }
            self.queue.async { self.complete(connectionID, request: request, outcome: outcome) }
        }
    }

    private func complete(_ connectionID: Int, request: Request, outcome: HandlerOutcome) {
        guard let connection = connections[connectionID] else { return }
        switch outcome {
        case .respond(let outcome):
            connection.finish(with: Response(id: request.id, outcome: outcome))
        case .stream(let streamRequest):
            guard !connection.peerStoppedSending else {
                connection.close()
                return
            }
            let stream = ServerConnection.Stream(request: streamRequest, requestID: request.id, client: request.client, openedAt: Date())
            connection.phase = .streaming(stream)
            if let timeout = streamRequest.timeout {
                connection.schedule(after: timeout.after) { [weak self, weak connection] in
                    guard let self, let connection, case .streaming(let stream) = connection.phase else { return }
                    self.deliver(timeout.event, to: connection, stream: stream)
                }
            }
            publishLiveStreams()
        }
    }

    private func deliver(_ event: StreamEvent, to connection: ServerConnection, stream: ServerConnection.Stream) {
        let response = Response(id: stream.requestID, outcome: .success(result: event.result, text: event.text))
        switch stream.request.mode {
        case .wait: connection.finish(with: response)
        case .watch: connection.send(response.line())
        }
    }

    private func closed(_ connection: ServerConnection) {
        connections[connection.id] = nil
        if connection.wasStreaming { publishLiveStreams() }
    }

    private func publishLiveStreams() {
        liveStreamContinuation.yield(currentLiveStreams())
    }

    private func currentLiveStreams() -> [LiveStream] {
        connections.values.sorted { $0.id < $1.id }.compactMap { connection in
            guard case .streaming(let stream) = connection.phase else { return nil }
            return LiveStream(connection: connection.id, mode: stream.request.mode, listener: stream.request.listener,
                              stack: stream.request.stack, client: stream.client, openedAt: stream.openedAt)
        }
    }
}

/// Why the socket could not start.
public enum SocketServerError: Error, Sendable, Hashable, CustomStringConvertible {
    case alreadyStarted
    case socketPathTooLong(bytes: Int)
    /// A socket file is already there, and the caller does not hold the instance lock.
    case socketExists
    /// Something other than a socket sits at the socket path, so it is left alone.
    case notASocket
    case unsafeRunFolder
    case system(SystemCallError)

    public var description: String {
        switch self {
        case .alreadyStarted:
            "The socket server has already started. Create a new one to listen again."
        case .socketPathTooLong(let bytes):
            "The socket path is \(bytes) bytes, over the \(UnixSocket.maximumPathBytes)-byte limit. Set EYEBALLS_HOME to a shorter folder."
        case .socketExists:
            "A socket file already exists. Only the app holding run/app.lock may remove it."
        case .notASocket:
            "Something other than a socket is at the socket path. Move it away, then start Eyeballs again."
        case .unsafeRunFolder:
            "The run folder must be a folder you own with permissions 0700."
        case .system(let error):
            "The socket could not start: \(error.description)."
        }
    }
}
