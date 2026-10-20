import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation

extension ReviewService {
    /// `eyeballs hook`: Claude Code's SessionStart, Stop and SessionEnd hooks. It never fails,
    /// because a failing hook would show an error on every turn. Its text holds counts and
    /// commands, never comment bodies.
    func hook(_ arguments: HookArguments, client: ClientIdentity) async -> HookResult {
        var hookClient = client
        if let cwd = arguments.input?["cwd"]?.stringValue, cwd.hasPrefix("/") { hookClient.cwd = cwd }
        let client = hookClient
        let hookSession = arguments.input?["session_id"]?.stringValue
        do {
            switch arguments.event {
            case .sessionStart:
                return try await sessionStart(client, hookSession: hookSession, source: arguments.input?["source"]?.stringValue ?? "startup")
            case .stop:
                return try await oneAtATime.run { try await self.stop(client, hookSession: hookSession) }
            case .sessionEnd:
                try sessionEnd(client, hookSession: hookSession)
                return HookResult(output: nil)
            default:
                return HookResult(output: nil)
            }
        } catch {
            Log.server.error("The \(arguments.event.rawValue, privacy: .public) hook failed: \(String(describing: error), privacy: .public)")
            return HookResult(output: nil)
        }
    }

    /// Rebinds the driver role by `CLAUDE_PID` only when the source is `clear`, so an in-process
    /// `/resume` of another conversation cannot take it. Prints context only when the
    /// session has state, in 600 characters or fewer.
    private func sessionStart(_ client: ClientIdentity, hookSession: String?, source: String) async throws -> HookResult {
        guard let session = try register(client, hookSession: hookSession) else { return HookResult(output: nil) }
        if source == "clear", let process = Self.process(of: session) {
            for old in try store.sessions(withProcessIn: [process.pid]) where old.id != session.id && old.pidStart == session.pidStart {
                for stack in try store.stacksDriven(bySession: old.id) {
                    try store.setDriver(stackID: stack.id, sessionID: session.id)
                    notify(.stack(stack.id))
                }
            }
        }

        if let stack = try store.stacksDriven(bySession: session.id).first {
            let facts = try facts(stack.id)
            let reviewer = await reviewerName(for: facts.repo)
            let at = facts.latestRevision.map { " at r\($0.number)" } ?? ""
            var text = "Eyeballs: you drive \(stackLabel(stack))\(at)."
            let waiting = try store.threadsWaitingOnAgent(stackID: stack.id)
            if let review = facts.reviews.last(where: { $0.status == .submitted }) {
                text += " Review \(review.id) is waiting. Run eyeballs inbox."
            } else if !waiting.isEmpty {
                let unreplied = AgentText.list(waiting.map { "t\($0.thread.id)" })
                text += " \(unreplied) \(waiting.count == 1 ? "has" : "have") no reply. Run eyeballs inbox."
            }
            text += " Only \(reviewer.inSentence) resolves threads."
            return HookResult(output: HookOutput.sessionStartContext(text))
        }
        if source == "fork", let here = try await knownStack(nil, client: client, session: nil),
           let driver = try here.driverSession.flatMap({ try store.session(id: $0) }), driver.id != session.id {
            return HookResult(output: HookOutput.sessionStartContext(
                "Eyeballs: another session drives \(stackLabel(here)). Run eyeballs attach to take over, then eyeballs inbox."))
        }
        return HookResult(output: nil)
    }

    /// The Stop hook: blocks once per reason, recorded in `stop_block`.
    ///
    /// There is no early exit on `stop_hook_active`, because that flag stays true for the whole
    /// continuation. There is no "a wait is connected" shortcut either, because that wait may
    /// belong to a subagent.
    private func stop(_ client: ClientIdentity, hookSession: String?) async throws -> HookResult {
        guard let session = try register(client, hookSession: hookSession) else { return HookResult(output: nil) }
        var reasons: [(key: String, text: String)] = []
        for stack in try store.stacksDriven(bySession: session.id) {
            let facts = try facts(stack.id)
            let reviewer = await reviewerName(for: facts.repo)
            let waiting = try store.threadsWaitingOnAgent(stackID: stack.id)

            for review in facts.reviews.reversed() where review.status == .submitted {
                let threads = threadCount(of: review, in: facts)
                let text = review.verdict == .approved && threads == 0
                    ? "\(reviewer.startingSentence) approved review \(review.id). Run eyeballs inbox."
                    : "\(reviewer.startingSentence) submitted review \(review.id) (\(AgentText.count(threads, "thread"))). Run eyeballs inbox."
                reasons.append(("undelivered:\(review.id)", text))
            }
            for thread in waiting {
                for comment in thread.unanswered where comment.reviewID == nil && comment.deliveredAt == nil {
                    reasons.append(("undelivered:c\(comment.id)", "\(reviewer.startingSentence) sent a comment on t\(thread.thread.id). Run eyeballs inbox."))
                }
            }

            var unrepliedByReview: [Int: [Int]] = [:]
            for thread in waiting where thread.wasShown {
                let shown = thread.unanswered.filter { $0.deliveredAt != nil }
                if let review = shown.compactMap(\.reviewID).first {
                    unrepliedByReview[review, default: []].append(thread.thread.id)
                } else if let comment = shown.first {
                    reasons.append(("unreplied:c\(comment.id)", "t\(thread.thread.id) has no reply. Reply with eyeballs reply, then run eyeballs review."))
                }
            }
            for (review, threads) in unrepliedByReview.sorted(by: { $0.key < $1.key }) {
                let ids = AgentText.list(threads.map { "t\($0)" })
                reasons.append(("unreplied:\(review)", "\(ids) from review \(review) \(threads.count == 1 ? "has" : "have") no reply. Reply with eyeballs reply, then run eyeballs review."))
            }
        }
        let fresh = try reasons.filter { try store.recordStopBlock(sessionID: session.id, reasonKey: $0.key) }
        guard !fresh.isEmpty else { return HookResult(output: nil) }
        return HookResult(output: HookOutput.block(reason: "Eyeballs: " + fresh.map(\.text).joined(separator: " ")))
    }

    /// Marks the session ended. It keeps the driver role until another session takes it.
    private func sessionEnd(_ client: ClientIdentity, hookSession: String?) throws {
        guard let key = client.session ?? hookSession else { return }
        let agent = AgentKind(rawValue: client.session == nil && client.agent == "other" ? "claude" : client.agent)
        guard let session = try store.session(agent: agent, key: key) else { return }
        try store.endAgentSession(id: session.id)
    }

    // MARK: open

    /// `eyeballs open [PATH]`: brings the window to the front. With a path, it opens that repo's
    /// stack; without one, it shows the stack the caller is working on and never adds a stack.
    func open(_ arguments: OpenArguments, client: ClientIdentity) async throws -> (OpenResult, String) {
        let session = try register(client)
        if let path = arguments.path {
            let opened = try await openRepository(at: URL(fileURLWithPath: path, isDirectory: true))
            showWindow(forStack: opened.stack.id, focus: true, select: true)
            let summary = summary(of: opened.stack, repo: opened.repo)
            return (OpenResult(repo: summary.repo, stacks: [summary]), "Opened \(stackLabel(opened.stack)) in Eyeballs.")
        }
        guard let stack = try await knownStack(nil, client: client, session: session), let repo = try store.repo(id: stack.repoID) else {
            showWindow(forStack: nil, focus: true, select: false)
            return (OpenResult(repo: "", stacks: []),
                    "Brought Eyeballs to the front. To open a repo it does not know yet, run eyeballs open with the repo's folder.")
        }
        showWindow(forStack: stack.id, focus: true, select: true)
        let summary = summary(of: stack, repo: repo)
        return (OpenResult(repo: summary.repo, stacks: [summary]), "Showing \(stackLabel(stack)) in Eyeballs.")
    }

    // MARK: doctor

    /// The app's half of `eyeballs doctor`: who it is, and the store's invariants.
    func health() async -> AppHealth {
        var checks = [DoctorCheck(name: "Store", status: .passed, message: "\(app.home.database.path), install ID \(store.installID)")]
        do {
            let stacks = try store.activeStacks()
            var missing: [String] = []
            for stack in stacks {
                guard let facts = try store.facts(stackID: stack.id), let latest = facts.latestRevision else { continue }
                for thread in facts.threads where thread.status == .open && !(facts.anchors[thread.id] ?? []).contains(where: { $0.revisionID == latest.id }) {
                    missing.append("t\(thread.id)")
                }
                if facts.reviews.filter({ $0.status == .draft }).count > 1 {
                    checks.append(DoctorCheck(name: "Drafts", status: .failed, message: "s\(stack.id) has more than one draft review."))
                }
            }
            checks.append(missing.isEmpty
                ? DoctorCheck(name: "Anchors", status: .passed, message: "Every open thread has an anchor on its stack's latest revision.")
                : DoctorCheck(name: "Anchors", status: .failed, message: "\(AgentText.list(missing)) \(missing.count == 1 ? "has" : "have") no anchor on the latest revision."))
            checks.append(await pinCheck())
        } catch {
            checks.append(DoctorCheck(name: "Store", status: .failed, message: "The store could not be read: \(String(describing: error))"))
        }
        return AppHealth(version: app.version, build: app.build, path: app.bundlePath, home: app.home.root.path, checks: checks)
    }

    /// Every pin row has its ref in the repository.
    private func pinCheck() async -> DoctorCheck {
        var missing = 0
        var unreadable: [String] = []
        for repo in (try? store.repos()) ?? [] {
            guard let pins = try? store.livePins(repoID: repo.id), !pins.isEmpty else { continue }
            guard let repository = try? await repository(for: repo),
                  let pinned = try? await PinStore(repository: repository, installID: store.installID).pinnedCommits() else {
                unreadable.append(Self.workTreePath(of: repo))
                continue
            }
            missing += pins.filter { pin in ObjectID(pin.sha).map { !pinned.contains($0) } ?? true }.count
        }
        if missing > 0 { return DoctorCheck(name: "Pins", status: .failed, message: "\(AgentText.count(missing, "pin")) in the store \(missing == 1 ? "has" : "have") no ref.") }
        if !unreadable.isEmpty { return DoctorCheck(name: "Pins", status: .warning, message: "Could not read the pins in \(AgentText.list(unreadable)).") }
        return DoctorCheck(name: "Pins", status: .passed, message: "Every pin in the store has its ref.")
    }
}
