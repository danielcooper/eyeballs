import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation
import Synchronization
import Testing

/// A throwaway repo with a two-layer stack, `a` on `main` and `b` on `a`, plus a store in a
/// temporary Eyeballs home and a service that talks to a fake socket.
///
/// `a.txt` has 20 numbered lines on `main`; layer `a` adds lines 21 and 22, and layer `b` adds `b.txt`.
final class BackendFixture: Sendable {
    let repo: URL
    let home: EyeballsHome
    let store: Store
    let service: ReviewService
    let sink = FakeSink()
    let agent: ClientIdentity

    static let agentProcess = ClaudeProcess(pid: 4242, start: 1_760_000_000)
    static let otherProcess = ClaudeProcess(pid: 5151, start: 1_760_000_100)

    init() throws {
        let id = UInt32.random(in: .min ... .max)
        repo = URL(fileURLWithPath: "/tmp/eb-bt-repo-\(id)", isDirectory: true)
        home = EyeballsHome(root: URL(fileURLWithPath: "/tmp/eb-bt-\(id)", isDirectory: true))
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Self.git(repo, "init", "-q", "-b", "main")
        try Self.git(repo, "config", "user.name", "Alex")
        try Self.write(repo, "a.txt", (1...20).map { "line \($0)" })
        try Self.git(repo, "add", "a.txt")
        try Self.git(repo, "commit", "-q", "-m", "Base")
        try Self.git(repo, "checkout", "-q", "-b", "a")
        try Self.write(repo, "a.txt", (1...22).map { "line \($0)" })
        try Self.git(repo, "commit", "-q", "-am", "Add two lines")
        try Self.git(repo, "checkout", "-q", "-b", "b")
        try Self.write(repo, "b.txt", ["hello"])
        try Self.git(repo, "add", "b.txt")
        try Self.git(repo, "commit", "-q", "-m", "Add b")

        store = try Store.open(home: home, appVersion: "0.1.0-test")
        let facts = AppFacts(version: "0.1.0", build: "1", bundlePath: "/Applications/Eyeballs.app", home: home)
        let alive: Set<ClaudeProcess> = [Self.agentProcess, Self.otherProcess]
        let processes = ProcessInspector(
            startTime: { pid in alive.first { $0.pid == pid }?.start },
            parent: { _ in nil })
        service = ReviewService(store: store, app: facts, processes: processes)
        service.connect(sink)
        agent = Self.client(session: "session-1", process: Self.agentProcess, cwd: repo.path)
    }

    deinit {
        try? store.close()
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: home.root)
    }

    static func client(session: String?, process: ClaudeProcess?, cwd: String, ancestors: [Int32] = []) -> ClientIdentity {
        ClientIdentity(agent: "claude", session: session, pid: process?.pid, pidStart: process?.start, ancestors: ancestors, cwd: cwd)
    }

    /// `eyeballs review --branches a,b --trunk main`.
    @discardableResult
    func review(force: Bool = false, as client: ClientIdentity? = nil) async throws -> (ReviewResult, String) {
        try await service.review(ReviewArguments(branches: ["a", "b"], trunk: "main", force: force), client: client ?? agent)
    }

    /// Comments on lines of `a.txt` in layer `a`, at the newest revision, and submits the review.
    @discardableResult
    func submitComment(_ body: String, lines: ClosedRange<Int>, summary: String = "") async throws -> DebugSubmitReviewResult {
        try await service.debugSubmitReview(
            DebugSubmitReviewArguments(path: "a.txt", line: lines.lowerBound, endLine: lines.upperBound, body: body, summary: summary),
            client: agent).0
    }

    func inbox(peek: Bool = false, page: Int = 1, as client: ClientIdentity? = nil) async throws -> (InboxResult, String) {
        try await service.inbox(InboxArguments(page: page, peek: peek), client: client ?? agent)
    }

    func reply(_ batch: String, as client: ClientIdentity? = nil) async throws -> (ReplyResult, String) {
        try await service.reply(ReplyArguments(replies: try ReplyBatch.parse(batch)), client: client ?? agent)
    }

    /// The session key of the stack's driver.
    func driverKey() throws -> String? {
        guard let stack = try store.stack(id: try stackID()), let id = stack.driverSession else { return nil }
        return try store.session(id: id)?.sessionKey
    }

    func stackID() throws -> Int {
        try #require(store.activeStacks().first?.id)
    }

    // MARK: Changing the repo

    /// Rewrites `a.txt` on layer `a`, amends its commit, and rebases `b` onto it.
    func amendLayerA(_ lines: [String]) throws {
        try Self.git(repo, "checkout", "-q", "a")
        try Self.write(repo, "a.txt", lines)
        try Self.git(repo, "commit", "-q", "--amend", "-am", "Add two lines")
        try Self.git(repo, "checkout", "-q", "b")
        try Self.git(repo, "rebase", "-q", "--onto", "a", "HEAD~1", "b")
    }

    static func write(_ repo: URL, _ name: String, _ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    static func git(_ repo: URL, environment extra: [String: String] = [:], _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Eyeballs", "-c", "user.email=eyeballs@example.invalid", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = repo
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError("git \(arguments.joined(separator: " ")) exited with status \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct FixtureError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Records every event the service broadcasts, in place of the socket server.
final class FakeSink: AgentEventSink {
    private let state = Mutex<(events: [(StreamEvent, ListenerKey)], streams: [LiveStream])>(([], []))

    func broadcast(_ event: StreamEvent, to listener: ListenerKey) -> Int {
        state.withLock { $0.events.append((event, listener)) }
        return 1
    }

    func liveStreams() -> [LiveStream] {
        state.withLock { $0.streams }
    }

    var events: [(event: StreamEvent, listener: ListenerKey)] {
        state.withLock { $0.events.map { (event: $0.0, listener: $0.1) } }
    }
}
