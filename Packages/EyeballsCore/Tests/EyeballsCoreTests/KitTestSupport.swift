import Darwin
import EyeballsKit
import Foundation
import Synchronization
import Testing

/// A fresh folder under /tmp. Socket paths must stay under 104 bytes, and `$TMPDIR` alone is
/// about 50, so tests never use it.
struct TemporaryFolder: Sendable {
    let url: URL

    static func make() throws -> TemporaryFolder {
        var template = Array("/tmp/eb-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw SystemFailure(call: "mkdtemp") }
        return TemporaryFolder(url: URL(fileURLWithPath: String(cString: created), isDirectory: true))
    }

    var home: EyeballsHome { EyeballsHome(root: url.appendingPathComponent("home", isDirectory: true)) }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct SystemFailure: Error {
    var call: String
}

/// A request handler whose answers each test writes, and which remembers every request.
final class FakeHandler: RequestHandler {
    typealias Answer = @Sendable (Request, Peer) async throws -> HandlerOutcome

    private let answer: Answer
    private let received = Mutex<[Request]>([])

    init(_ answer: @escaping Answer) {
        self.answer = answer
    }

    func respond(to request: Request, from peer: Peer) async throws -> HandlerOutcome {
        received.withLock { $0.append(request) }
        return try await answer(request, peer)
    }

    var requests: [Request] { received.withLock { $0 } }

    /// Answers every request with its operation name as the text.
    static func echo() -> FakeHandler {
        FakeHandler { request, _ in
            try .success(EchoResult(operation: request.operation.rawValue, arguments: request.arguments), text: "did \(request.operation.rawValue)")
        }
    }
}

struct EchoResult: Codable, Sendable {
    var schema = "eyeballs.echo/1"
    var ok = true
    var operation: String
    var arguments: JSONValue
}

/// Collects values from any thread.
final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])

    func append(_ value: Value) {
        storage.withLock { $0.append(value) }
    }

    var values: [Value] { storage.withLock { $0 } }
}

/// Lets a blocking client cross into the closures `offPool` runs.
final class ClientBox: @unchecked Sendable {
    let client: SocketClient

    init(_ client: SocketClient) {
        self.client = client
    }
}

/// Runs blocking socket calls on a Dispatch thread, so they never starve the Swift
/// concurrency threads the server's handler needs.
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

let testProcess = ClaudeProcess(pid: 4242, start: 1_760_620_000)

func client(process: ClaudeProcess? = testProcess, session: String? = "session-1") -> ClientIdentity {
    ClientIdentity(agent: "claude", session: session, pid: process?.pid, pidStart: process?.start, ancestors: [100, 50], cwd: "/Users/alex/src/shop")
}

func request(_ operation: OperationName, _ arguments: some Encodable, id: Int = 1,
             process: ClaudeProcess? = testProcess) throws -> Request {
    try Request(id: id, operation: operation, client: client(process: process), arguments: arguments)
}

func request(_ operation: OperationName, id: Int = 1, process: ClaudeProcess? = testProcess) throws -> Request {
    try request(operation, JSONObject(), id: id, process: process)
}

/// Starts a server in a fresh home, runs `body`, then stops it and removes the folder.
func withServer(
    _ handler: some RequestHandler,
    limits: SocketServer.Limits = .standard,
    allowedUser: uid_t = geteuid(),
    _ body: (SocketServer, EyeballsHome) async throws -> Void
) async throws {
    let folder = try TemporaryFolder.make()
    defer { folder.remove() }
    let server = SocketServer(home: folder.home, handler: handler, limits: limits, allowedUser: allowedUser)
    try server.start(holdingInstanceLock: true)
    defer { server.stop() }
    try await body(server, folder.home)
}

func connect(_ home: EyeballsHome) async throws -> ClientBox {
    try await offPool { ClientBox(try SocketClient.connect(to: home.socket, timeout: .seconds(2))) }
}

func exchange(_ request: Request, at home: EyeballsHome, timeout: Duration = .seconds(5)) async throws -> Response {
    let box = try await connect(home)
    return try await offPool { try box.client.exchange(request, timeout: timeout) }
}

extension Response {
    var successText: String? {
        if case .success(_, let text) = outcome { return text }
        return nil
    }

    var successResult: JSONValue? {
        if case .success(let result, _) = outcome { return result }
        return nil
    }

    var failure: EyeballsError? {
        if case .failure(let error) = outcome { return error }
        return nil
    }
}
