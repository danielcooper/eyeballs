import Darwin
import EyeballsKit
import Foundation
import Testing

/// Starts a real `SocketServer` in a short temporary home and drives it with `SocketClient`.
@Suite(.serialized)
struct KitServerTests {
    @Test func answersOneRequestAndCloses() async throws {
        let handler = FakeHandler.echo()
        try await withServer(handler) { _, home in
            let box = try await connect(home)
            let response = try await offPool { try box.client.exchange(try request(.inbox, InboxArguments(page: 2), id: 7), timeout: .seconds(5)) }
            #expect(response.id == 7)
            #expect(response.successText == "did inbox")
            #expect(response.successResult?["arguments"]?["page"] == .integer(2))
            await #expect(throws: SocketClientError.closedBeforeResponse) {
                try await offPool { try box.client.receive(timeout: .seconds(2)) }
            }
        }
        #expect(handler.requests.map(\.client) == [client()])
    }

    @Test func waitGetsOneEventThenCloses() async throws {
        try await withServer(Self.streamingHandler()) { server, home in
            let box = try await connect(home)
            try await offPool { try box.client.send(try request(.wait, id: 3), timeout: .seconds(2)) }
            #expect(await eventually { server.liveStreams().count == 1 })
            #expect(server.liveStreams().first?.mode == .wait)

            let event = try Self.submittedEvent()
            #expect(server.broadcast(event, to: .claudeProcess(testProcess)) == 1)
            let response = try await offPool { try box.client.receive(timeout: .seconds(2)) }
            #expect(response.id == 3)
            #expect(response.successText == event.text)
            #expect(response.successResult == event.result)
            await #expect(throws: SocketClientError.closedBeforeResponse) {
                try await offPool { try box.client.receive(timeout: .seconds(2)) }
            }
            #expect(await eventually { server.liveStreams().isEmpty })
        }
    }

    @Test func watchStreamsEventsUntilItDisconnects() async throws {
        try await withServer(Self.streamingHandler()) { server, home in
            let box = try await connect(home)
            try await offPool { try box.client.send(try request(.watch, id: 5), timeout: .seconds(2)) }
            #expect(await eventually { server.liveStreams().count == 1 })

            for number in 1...3 {
                let event = try StreamEvent(WaitEvent(event: .commentSent, stack: StackID(3), threads: 1), text: "event \(number)", stack: StackID(3))
                #expect(server.broadcast(event, to: .claudeProcess(testProcess)) == 1)
                let response = try await offPool { try box.client.receive(timeout: .seconds(2)) }
                #expect(response.id == 5)
                #expect(response.successText == "event \(number)")
            }
            box.client.close()
            #expect(await eventually { server.liveStreams().isEmpty })
        }
    }

    @Test func waitTimesOutWithTheHandlersEvent() async throws {
        let handler = FakeHandler { request, _ in
            let timeout = StreamTimeout(after: .milliseconds(200), event: WaitEvent.timeoutEvent(after: .seconds(1), stack: nil))
            return .stream(StreamRequest(mode: .wait, listener: .claudeProcess(testProcess), timeout: timeout))
        }
        try await withServer(handler) { server, home in
            let response = try await exchange(try request(.wait), at: home)
            #expect(response.successResult?["event"] == .string("timeout"))
            #expect(await eventually { server.liveStreams().isEmpty })
        }
    }

    @Test func broadcastReachesEveryConnectionOfOneClaudeProcess() async throws {
        let other = ClaudeProcess(pid: 5151, start: 1_760_620_500)
        try await withServer(Self.streamingHandler()) { server, home in
            let firstWait = try await connect(home)
            let secondWait = try await connect(home)
            let monitor = try await connect(home)
            let otherWait = try await connect(home)
            try await offPool {
                try firstWait.client.send(try request(.wait, id: 1), timeout: .seconds(2))
                try secondWait.client.send(try request(.wait, id: 2), timeout: .seconds(2))
                try monitor.client.send(try request(.watch, id: 3), timeout: .seconds(2))
                try otherWait.client.send(try request(.wait, id: 4, process: other), timeout: .seconds(2))
            }
            #expect(await eventually { server.liveStreams().count == 4 })

            let event = try Self.submittedEvent()
            #expect(server.broadcast(event, to: .claudeProcess(testProcess)) == 3)
            for (box, id) in [(firstWait, 1), (secondWait, 2), (monitor, 3)] {
                let response = try await offPool { try box.client.receive(timeout: .seconds(2)) }
                #expect(response.id == id)
                #expect(response.successText == event.text)
            }
            await #expect(throws: SocketClientError.timedOut(seconds: 1)) {
                try await offPool { try otherWait.client.receive(timeout: .milliseconds(300)) }
            }
            #expect(await eventually { server.liveStreams().map(\.connection).count == 2 })
            #expect(Set(server.liveStreams().map(\.mode)) == [.watch, .wait])
        }
    }

    @Test func aWaitForOneStackSkipsEventsAboutAnother() async throws {
        let handler = FakeHandler { request, _ in
            let arguments = try request.decodeArguments(WaitArguments.self)
            guard case .id(let stack)? = arguments.stack else { throw EyeballsError(.noStack, "No stack.") }
            return .stream(StreamRequest(mode: .wait, listener: .claudeProcess(testProcess), stack: stack))
        }
        try await withServer(handler) { server, home in
            let box = try await connect(home)
            try await offPool { try box.client.send(try request(.wait, WaitArguments(stack: .id(StackID(5)))), timeout: .seconds(2)) }
            #expect(await eventually { server.liveStreams().count == 1 })
            let aboutThree = try StreamEvent(WaitEvent(event: .commentSent, stack: StackID(3)), text: "s3", stack: StackID(3))
            let aboutFive = try StreamEvent(WaitEvent(event: .commentSent, stack: StackID(5)), text: "s5", stack: StackID(5))
            #expect(server.broadcast(aboutThree, to: .claudeProcess(testProcess)) == 0)
            #expect(server.broadcast(aboutFive, to: .claudeProcess(testProcess)) == 1)
            let response = try await offPool { try box.client.receive(timeout: .seconds(2)) }
            #expect(response.successText == "s5")
        }
    }

    @Test func aNewerProtocolGetsVersionMismatch() async throws {
        let handler = FakeHandler.echo()
        try await withServer(handler) { _, home in
            let box = try await connect(home)
            let line = Data(#"{"v":2,"id":11,"op":"inbox","client":{},"args":{}}"#.utf8 + [UInt8(ascii: "\n")])
            let response = try await offPool {
                try box.client.send(line: line, timeout: .seconds(2))
                return try box.client.receive(timeout: .seconds(2))
            }
            #expect(response.id == 11)
            #expect(response.failure?.code == .versionMismatch)
            #expect(response.failure?.message.contains("protocol 2") == true)
        }
        #expect(handler.requests.isEmpty)
    }

    @Test func refusesARequestOverOneMegabyte() async throws {
        let handler = FakeHandler.echo()
        try await withServer(handler) { _, home in
            let box = try await connect(home)
            let oversize = Data(repeating: UInt8(ascii: "a"), count: WireLimits.maximumRequestBytes + 100)
            let response = try await offPool {
                do {
                    try box.client.send(line: oversize, timeout: .seconds(5))
                } catch SocketClientError.closedBeforeResponse {
                    // The server stopped reading once it passed the limit.
                }
                return try box.client.receive(timeout: .seconds(5))
            }
            #expect(response.failure?.code == .badInput)
            #expect(response.failure?.message.contains("1024 KB") == true)
        }
        #expect(handler.requests.isEmpty)
    }

    @Test func theClientRefusesToSendAnOversizeRequest() async throws {
        try await withServer(FakeHandler.echo()) { _, home in
            let body = String(repeating: "x", count: WireLimits.maximumRequestBytes)
            let oversize = try request(.reply, ReplyArguments(replies: [ReplyItem(thread: ThreadID(1), status: .addressed, body: body)]))
            let box = try await connect(home)
            await #expect(throws: SocketClientError.self) {
                try await offPool { try box.client.send(oversize, timeout: .seconds(2)) }
            }
        }
    }

    @Test func answersMalformedLinesWithBadInput() async throws {
        let handler = FakeHandler.echo()
        try await withServer(handler) { _, home in
            let box = try await connect(home)
            let response = try await offPool {
                try box.client.send(line: Data("this is not json\n".utf8), timeout: .seconds(2))
                return try box.client.receive(timeout: .seconds(2))
            }
            #expect(response.failure?.code == .badInput)
        }
        #expect(handler.requests.isEmpty)
    }

    @Test func refusesOtherUsers() async throws {
        let handler = FakeHandler.echo()
        try await withServer(handler, allowedUser: geteuid() &+ 1) { _, home in
            await #expect(throws: SocketClientError.closedBeforeResponse) {
                try await exchange(try request(.status), at: home)
            }
        }
        #expect(handler.requests.isEmpty)
    }

    @Test func handlerErrorsReachTheClient() async throws {
        let handler = FakeHandler { request, _ in
            struct Surprise: Error {}
            if request.operation == .show { throw EyeballsError(.unknownThread, "There is no thread t99.") }
            throw Surprise()
        }
        try await withServer(handler) { _, home in
            let known = try await exchange(try request(.show), at: home)
            #expect(known.failure == EyeballsError(.unknownThread, "There is no thread t99."))
            let unknown = try await exchange(try request(.inbox), at: home)
            #expect(unknown.failure?.code == .internalError)
        }
    }

    @Test func handlesManyConnectionsAtOnce() async throws {
        let handler = FakeHandler { request, _ in
            try await Task.sleep(for: .milliseconds(50))
            return try .success(EchoResult(operation: "status", arguments: .integer(Int64(request.id))), text: "\(request.id)")
        }
        try await withServer(handler) { _, home in
            try await withThrowingTaskGroup(of: (Int, String?).self) { group in
                for id in 1...40 {
                    group.addTask { (id, try await exchange(try request(.status, id: id), at: home).successText) }
                }
                var answered = 0
                for try await (id, text) in group {
                    #expect(text == "\(id)")
                    answered += 1
                }
                #expect(answered == 40)
            }
        }
    }

    @Test func aClientThatHangsUpStillGetsItsRequestHandled() async throws {
        let handler = FakeHandler.echo()
        try await withServer(handler) { _, home in
            let box = try await connect(home)
            try await offPool {
                try box.client.send(try request(.hook, HookArguments(event: .sessionEnd, input: nil)), timeout: .seconds(2))
                box.client.close()
            }
            #expect(await eventually { handler.requests.count == 1 })
            #expect(handler.requests.first?.operation == .hook)
        }
    }

    @Test func closesAClientThatSendsNothing() async throws {
        var limits = SocketServer.Limits()
        limits.requestTimeout = .milliseconds(200)
        try await withServer(FakeHandler.echo(), limits: limits) { _, home in
            let box = try await connect(home)
            await #expect(throws: SocketClientError.closedBeforeResponse) {
                try await offPool { try box.client.receive(timeout: .seconds(3)) }
            }
        }
    }

    @Test func publishesLiveStreamChanges() async throws {
        try await withServer(Self.streamingHandler()) { server, home in
            let watcher = Task { () -> [LiveStream]? in
                for await streams in server.liveStreamChanges where !streams.isEmpty { return streams }
                return nil
            }
            let box = try await connect(home)
            try await offPool { try box.client.send(try request(.watch), timeout: .seconds(2)) }
            let streams = await watcher.value
            #expect(streams?.count == 1)
            #expect(streams?.first?.listener == .claudeProcess(testProcess))
            #expect(streams?.first?.client == client())
        }
    }

    @Test func createsPrivateFoldersAndSocket() async throws {
        try await withServer(FakeHandler.echo()) { _, home in
            var folder = stat()
            var socket = stat()
            #expect(lstat(home.run.path, &folder) == 0)
            #expect(lstat(home.socket.path, &socket) == 0)
            #expect(folder.st_mode & 0o777 == 0o700)
            #expect(socket.st_mode & 0o777 == 0o600)
            #expect(socket.st_mode & S_IFMT == S_IFSOCK)
        }
    }

    @Test func removesAStaleSocketOnlyWithTheInstanceLock() async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        try folder.home.prepare()
        try Self.leaveStaleSocket(at: folder.home.socket.path)

        let server = SocketServer(home: folder.home, handler: FakeHandler.echo())
        #expect(throws: SocketServerError.socketExists) { try server.start(holdingInstanceLock: false) }
        try server.start(holdingInstanceLock: true)
        defer { server.stop() }
        #expect(throws: SocketServerError.alreadyStarted) { try server.start(holdingInstanceLock: true) }
        let response = try await exchange(try request(.status), at: folder.home)
        #expect(response.successText == "did status")
    }

    @Test func neverRemovesSomethingThatIsNotASocket() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        try folder.home.prepare()
        try Data("keep me".utf8).write(to: folder.home.socket)
        let server = SocketServer(home: folder.home, handler: FakeHandler.echo())
        #expect(throws: SocketServerError.notASocket) { try server.start(holdingInstanceLock: true) }
        #expect(try String(contentsOf: folder.home.socket, encoding: .utf8) == "keep me")
    }

    @Test func refusesASocketPathThatIsTooLong() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let home = EyeballsHome(root: folder.url.appendingPathComponent(String(repeating: "x", count: 90), isDirectory: true))
        let server = SocketServer(home: home, handler: FakeHandler.echo())
        #expect(throws: SocketServerError.socketPathTooLong(bytes: home.socket.path.utf8.count)) {
            try server.start(holdingInstanceLock: true)
        }
        #expect(throws: SocketClientError.pathTooLong(bytes: home.socket.path.utf8.count)) {
            _ = try SocketClient.connect(to: home.socket, timeout: .seconds(1))
        }
    }

    @Test func stopRemovesTheSocket() async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let server = SocketServer(home: folder.home, handler: FakeHandler.echo())
        try server.start(holdingInstanceLock: true)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: folder.home.socket.path))
        #expect(throws: SocketClientError.notRunning) {
            _ = try SocketClient.connect(to: folder.home.socket, timeout: .seconds(1))
        }
    }

    /// Opens `wait` and `watch` as streams for the caller's own listener key.
    static func streamingHandler() -> FakeHandler {
        FakeHandler { request, _ in
            guard let listener = ListenerKey(client: request.client) else { throw EyeballsError(.badInput, "No listener.") }
            return .stream(StreamRequest(mode: request.operation == .watch ? .watch : .wait, listener: listener))
        }
    }

    static func submittedEvent() throws -> StreamEvent {
        try StreamEvent(
            WaitEvent(event: .reviewSubmitted, stack: StackID(3), review: 7, threads: 5, verdict: .changesRequested),
            text: "eyeballs: Alex submitted review 7 on checkout-v2 (s3, r4): 5 threads, changes requested. Run: eyeballs inbox",
            stack: StackID(3))
    }

    /// Binds a socket and closes it without removing the file, as a crashed app would.
    static func leaveStaleSocket(at path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw SystemFailure(call: "bind") }
    }
}
