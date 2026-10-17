import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation
import Synchronization

/// The one place that changes reviews: for agents over the socket, and for you in the window.
///
/// Every flow that reads and then writes runs inside `oneAtATime`, so two requests never
/// interleave half way through, for example two `eyeballs review` runs porting the same thread.
/// The store blocks the calling thread, so nothing here runs on the main actor.
final class ReviewService: Sendable {
    let store: Store
    let app: AppFacts
    let processes: ProcessInspector
    let oneAtATime = OneAtATime()
    let layerDiffs = LayerDiffCache()

    private let sink = Mutex<(any AgentEventSink)?>(nil)
    private let observer = Mutex<(any ReviewServiceObserver)?>(nil)
    private let repositories = Mutex<[String: GitRepository]>([:])
    private let reviewerNames = Mutex<[Int: ReviewerName]>([:])

    init(store: Store, app: AppFacts, processes: ProcessInspector = .live) {
        self.store = store
        self.app = app
        self.processes = processes
    }

    /// Connects the socket server, so events reach `wait` and `watch` connections.
    func connect(_ sink: any AgentEventSink) {
        self.sink.withLock { $0 = sink }
    }

    func setObserver(_ observer: any ReviewServiceObserver) {
        self.observer.withLock { $0 = observer }
    }

    func notify(_ change: ReviewChange) {
        observer.withLock { $0 }?.reviewDidChange(change)
    }

    /// Brings the window to the front. With `select`, it also switches to `stackID`; without, it
    /// picks that stack only when nothing is shown yet.
    func showWindow(forStack stackID: Int?, focus: Bool, select: Bool = false) {
        observer.withLock { $0 }?.showWindow(forStack: stackID, focus: focus, select: select)
    }

    #if DEBUG
    /// Asks the window to draw itself into a PNG, for `debug.snapshotWindow`.
    func snapshotWindow(to path: String) async -> Bool {
        guard let window = observer.withLock({ $0 }) as? any WindowSnapshotting else { return false }
        return await window.snapshotWindow(to: path)
    }
    #endif

    /// Sends an event to every live `wait` and `watch` connection of one listener (fix 10).
    @discardableResult
    func broadcast(_ event: StreamEvent, to listener: ListenerKey) -> Int {
        sink.withLock { $0 }?.broadcast(event, to: listener) ?? 0
    }

    var liveStreams: [LiveStream] {
        sink.withLock { $0 }?.liveStreams() ?? []
    }

    /// What a listener has connected: `wait`, `monitor`, both or neither.
    func listening(_ listener: ListenerKey?) -> [Listener] {
        guard let listener else { return [] }
        let modes = Set(liveStreams.filter { $0.listener == listener }.map(\.mode))
        return [modes.contains(.wait) ? Listener.wait : nil, modes.contains(.watch) ? Listener.monitor : nil].compactMap { $0 }
    }

    // MARK: Sessions and the driver

    /// Registers the caller's session on its first call and refreshes it on later ones.
    ///
    /// Returns nil when the caller names no session. A hook passes the session from its input,
    /// because a hook's environment may lack `CLAUDE_CODE_SESSION_ID`. When the caller does not
    /// name its Claude process, the nearest ancestor that a registered session runs in stands in,
    /// so a hook or a monitor keeps the PID that routes wake-ups.
    func register(_ client: ClientIdentity, hookSession: String? = nil) throws -> AgentSessionRecord? {
        guard let key = client.session ?? hookSession else { return nil }
        let agent = AgentKind(rawValue: client.session == nil && client.agent == "other" ? "claude" : client.agent)
        let existing = try store.session(agent: agent, key: key)
        let process = try client.claudeProcess ?? claudeProcess(amongAncestors: client.ancestors) ?? existing.flatMap(Self.process(of:))
        return try store.upsertAgentSession(
            agent: agent, sessionKey: key, pid: process.map { Int($0.pid) }, pidStart: process.map { Int($0.start) }, cwd: client.cwd)
    }

    /// The nearest ancestor of the caller that a live registered session runs in.
    func claudeProcess(amongAncestors ancestors: [Int32]) throws -> ClaudeProcess? {
        let sessions = try store.sessions(withProcessIn: ancestors)
        for pid in ancestors {
            for session in sessions where session.pid == Int(pid) {
                if let process = Self.process(of: session), processes.isAlive(process) { return process }
            }
        }
        return nil
    }

    static func process(of session: AgentSessionRecord) -> ClaudeProcess? {
        guard let pid = session.pid, let start = session.pidStart else { return nil }
        return ClaudeProcess(pid: Int32(pid), start: Int64(start))
    }

    /// Where a session's events go: its Claude process when known, else the session itself.
    static func listener(for session: AgentSessionRecord) -> ListenerKey {
        if let process = process(of: session) { return .claudeProcess(process) }
        return .session(agent: session.agent.rawValue, session: session.sessionKey)
    }

    /// The caller's own listener key, as its `wait` and `watch` connections register it.
    static func listener(for client: ClientIdentity, session: AgentSessionRecord?) -> ListenerKey? {
        session.map(listener(for:)) ?? ListenerKey(client: client)
    }

    /// A session is alive until SessionEnd marks it, or until its Claude process is gone.
    /// A PID that was reused by a newer process has a different start time, so it is not alive.
    func isAlive(_ session: AgentSessionRecord) -> Bool {
        guard session.endedAt == nil else { return false }
        guard let pid = session.pid else { return true }
        guard let start = session.pidStart else { return processes.startTime(Int32(pid)) != nil }
        return processes.isAlive(ClaudeProcess(pid: Int32(pid), start: Int64(start)))
    }

    /// The driver rule for `inbox`, `wait` and `reply` (fix 11): the caller keeps the role, or
    /// takes it when no live session holds it.
    func claimIfFree(_ stack: StackRecord, by caller: AgentSessionRecord?) throws -> DriverStanding {
        let current = try stack.driverSession.flatMap { try store.session(id: $0) }
        if let current, current.id == caller?.id { return .driver }
        if let current, isAlive(current) { return .other(current) }
        guard let caller else { return .nobody }
        try store.setDriver(stackID: stack.id, sessionID: caller.id)
        Log.server.info("Session \(caller.id, privacy: .public) took over s\(stack.id, privacy: .public) from a driver that is gone")
        return .driver
    }

    /// For `review` and `attach`: the caller takes the role, and the old driver's connections
    /// get `rebound`. Returns true when another session drove the stack before.
    @discardableResult
    func takeDriverRole(of stack: StackRecord, for caller: AgentSessionRecord?) throws -> Bool {
        guard let caller else { return false }
        let current = try stack.driverSession.flatMap { try store.session(id: $0) }
        guard current?.id != caller.id else { return false }
        try store.setDriver(stackID: stack.id, sessionID: caller.id)
        if let current, isAlive(current), Self.listener(for: current) != Self.listener(for: caller) {
            let name = stackLabel(stack)
            broadcast(AgentEvents.rebound(stack: stack.id, label: name), to: Self.listener(for: current))
        }
        return current != nil
    }

    // MARK: Repositories

    /// The repository holding `folder`. One value is kept per worktree, because each owns a
    /// `git cat-file` process.
    func repository(at folder: URL) async throws -> GitRepository {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw EyeballsError(.notARepo, "The working folder no longer exists.", hint: "Run the command from your repository, or pass --stack.")
        }
        let located: GitRepository
        do {
            located = try await GitRepository.locate(from: folder)
        } catch GitError.notARepository {
            throw EyeballsError(.notARepo, "This folder is not inside a git repository.", hint: "Run the command from your repository, or pass --stack.")
        }
        return repositories.withLock { cache in
            if let cached = cache[located.gitDirectory.path] { return cached }
            cache[located.gitDirectory.path] = located
            return located
        }
    }

    func repository(for repo: RepoRecord) async throws -> GitRepository {
        try await repository(at: URL(fileURLWithPath: repo.commonDir, isDirectory: true))
    }

    /// Finds or creates the store's row for a repository.
    func recordRepo(_ repository: GitRepository, remote: String?) async throws -> RepoRecord {
        let roots = try await repository.git.run(["rev-list", "--max-parents=0", "HEAD", "--"], acceptedStatuses: [0, 128])
        let rootCommits = roots.text.split(separator: "\n").sorted().joined(separator: "\n")
        var remoteKey = remote
        if remoteKey == nil {
            let origin = try await repository.git.run(["config", "--get", "remote.origin.url"], acceptedStatuses: [0, 1])
            remoteKey = origin.status == 0 && !origin.text.isEmpty ? origin.text : nil
        }
        return try store.upsertRepo(commonDir: repository.commonDirectory.path, rootCommits: rootCommits, remoteKey: remoteKey)
    }

    /// `git config user.name` for the repo, or "the reviewer" when it is unset.
    func reviewerName(for repo: RepoRecord) async -> ReviewerName {
        if let known = reviewerNames.withLock({ $0[repo.id] }) { return known }
        var name = ReviewerName(name: nil)
        if let repository = try? await repository(for: repo),
           let result = try? await repository.git.run(["config", "user.name"], acceptedStatuses: [0, 1]),
           result.status == 0, !result.text.trimmingCharacters(in: .whitespaces).isEmpty {
            name = ReviewerName(name: result.text.trimmingCharacters(in: .whitespaces))
        }
        reviewerNames.withLock { $0[repo.id] = name }
        return name
    }

    /// For example `checkout-v2 (s3)`.
    func stackLabel(_ stack: StackRecord) -> String {
        "\(stack.name) (s\(stack.id))"
    }

    /// The repo's top-level folder, for results and the sidebar.
    static func workTreePath(of repo: RepoRecord) -> String {
        let url = URL(fileURLWithPath: repo.commonDir)
        return url.lastPathComponent == ".git" ? url.deletingLastPathComponent().path : url.path
    }

    func summary(of stack: StackRecord, repo: RepoRecord) -> StackSummary {
        StackSummary(id: StackID(stack.id), name: stack.name, source: StoredSource(rawValue: stack.source.rawValue).wire,
                     trunk: stack.trunkBranch, repo: Self.workTreePath(of: repo))
    }

    func facts(_ stackID: Int) throws -> StackFacts {
        guard let facts = try store.facts(stackID: stackID) else {
            throw EyeballsError(.noStack, "Stack s\(stackID) no longer exists.")
        }
        return facts
    }
}

/// What the window hears from the service.
enum ReviewChange: Sendable {
    /// Something in this stack changed: comments, replies, delivery or the driver.
    case stack(Int)
    /// The agent ran `eyeballs review`. `created` is false when nothing had changed.
    case agentReview(stackID: Int, revisionNumber: Int, created: Bool)
    /// A `wait` or `watch` connection opened or closed.
    case listeners([LiveStream])
}

protocol ReviewServiceObserver: AnyObject, Sendable {
    func reviewDidChange(_ change: ReviewChange)
    /// Brings the window to the front for this stack, taking keyboard focus only when `focus` is true.
    func showWindow(forStack stackID: Int?, focus: Bool, select: Bool)
}

#if DEBUG
/// A window that can draw itself into a PNG, for scripts that check what it shows.
protocol WindowSnapshotting: Sendable {
    func snapshotWindow(to path: String) async -> Bool
}
#endif

/// Where the live `wait` and `watch` connections are: the socket server, or a fake in tests.
protocol AgentEventSink: Sendable {
    @discardableResult
    func broadcast(_ event: StreamEvent, to listener: ListenerKey) -> Int
    func liveStreams() -> [LiveStream]
}

extension SocketServer: AgentEventSink {}

/// Facts about this run of the app, for `doctor`.
struct AppFacts: Sendable {
    var version: String
    var build: String
    var bundlePath: String
    var home: EyeballsHome
}

/// Where a caller stands under the driver rule.
enum DriverStanding: Sendable {
    case driver
    /// Another live session drives the stack.
    case other(AgentSessionRecord)
    /// The caller names no session, and no live session drives the stack.
    case nobody
}

/// The reviewer's name from `git config user.name`.
struct ReviewerName: Sendable, Hashable {
    var name: String?

    /// "Alex", or "the reviewer" mid-sentence.
    var inSentence: String { name ?? "the reviewer" }
    /// "Alex", or "The reviewer" at the start of a sentence.
    var startingSentence: String { name ?? "The reviewer" }
}

/// Runs async work one piece at a time, in the order it arrives.
actor OneAtATime {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        defer { handOver() }
        return try await work()
    }

    private func handOver() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// The diffs of recently shown layers, by snapshot. A snapshot never changes, so neither does its diff.
final class LayerDiffCache: Sendable {
    private static let limit = 24
    private let entries = Mutex<(diffs: [Int: LayerDiff], order: [Int])>(([:], []))

    func diff(forSnapshot id: Int) -> LayerDiff? {
        entries.withLock { $0.diffs[id] }
    }

    func store(_ diff: LayerDiff, forSnapshot id: Int) {
        entries.withLock { cache in
            if cache.diffs[id] == nil { cache.order.append(id) }
            cache.diffs[id] = diff
            while cache.order.count > Self.limit {
                cache.diffs[cache.order.removeFirst()] = nil
            }
        }
    }
}

/// One layer's commits and files, as the window shows them.
struct LayerDiff: Sendable {
    var commits: [CommitItem]
    var files: [FileItem]
}
