import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation

extension ReviewService {
    // MARK: reply

    /// `eyeballs reply`: saves every reply in the batch, or none.
    ///
    /// A reply from a session that does not drive the stack is saved with a `not_driver` warning,
    /// and one to a resolved thread with `thread_resolved`, because agent text is never lost
    /// (fix 11). When the driver is gone, the caller takes the role first.
    func reply(_ arguments: ReplyArguments, client: ClientIdentity) async throws -> (ReplyResult, String) {
        try await oneAtATime.run { try await self.replyNow(arguments, client: client) }
    }

    private func replyNow(_ arguments: ReplyArguments, client: ClientIdentity) async throws -> (ReplyResult, String) {
        let session = try register(client)
        let threads = try store.threads(ids: arguments.replies.map(\.thread.number)).filter { $0.deletedAt == nil }
        let byID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let unknown = arguments.replies.map(\.thread).filter { byID[$0.number] == nil }
        guard unknown.isEmpty else {
            let ids = AgentText.list(unknown.map(\.description))
            throw EyeballsError(.unknownThread, "\(ids) \(unknown.count == 1 ? "is not a thread" : "are not threads") in Eyeballs, so no reply was sent.",
                                hint: "Check the thread IDs with eyeballs inbox, then send the whole batch again.")
        }

        let stackIDs = Array(Set(threads.map(\.stackID))).sorted()
        var stacks: [StackRecord] = []
        var notDriving: [StackRecord] = []
        var reviewIDs = Set<Int>()
        for stackID in stackIDs {
            let facts = try facts(stackID)
            stacks.append(facts.stack)
            if case .other = try claimIfFree(facts.stack, by: session) { notDriving.append(facts.stack) }
            for thread in facts.threads where byID[thread.id] != nil {
                if let review = facts.sentComments(of: thread).last(where: { $0.author == .human })?.reviewID { reviewIDs.insert(review) }
            }
        }

        var warnings: [Warning] = []
        if !notDriving.isEmpty {
            let labels = AgentText.list(notDriving.map(stackLabel))
            warnings.append(Warning(code: .notDriver, message: "Another session drives \(labels). The replies are saved, and that session gets the wake-ups."))
        }
        var replied: [RepliedThread] = []
        for item in arguments.replies {
            guard let thread = byID[item.thread.number] else { continue }
            if thread.status == .resolved {
                warnings.append(Warning(code: .threadResolved, message: "\(item.thread) is resolved. The reply is saved, and the reviewer can reopen it.",
                                        thread: item.thread))
            }
            let comment = try store.addAgentReply(
                threadID: thread.id, status: AgentReplyStatus(item.status), body: item.body,
                atRanges: item.at.map { AtRange(path: $0.path, start: $0.start, end: $0.end) }, sessionID: session?.id)
            replied.append(RepliedThread(thread: item.thread, status: item.status, comment: CommentID(comment.id)))
        }

        var waiting: [WaitingThread] = []
        for stack in stacks {
            waiting += try store.threadsWaitingOnAgent(stackID: stack.id)
            notify(.stack(stack.id))
        }
        let result = ReplyResult(
            replied: replied, waitingOnYou: waiting.map { ThreadID($0.thread.id) }, warnings: warnings,
            next: waiting.isEmpty ? .runReview : .replyRemaining)
        let kinds = Dictionary(waiting.map { (ThreadID($0.thread.id), $0.kind.wire) }, uniquingKeysWith: { first, _ in first })
        let text = ReplyText.render(result, reviews: reviewIDs.sorted(), waitingKinds: kinds, stackLabels: notDriving.map(stackLabel))
        return (result, text)
    }

    // MARK: show

    /// `eyeballs show tN`: the whole thread, with the code at the newest revision and 5 lines of context.
    func show(_ arguments: ShowArguments, client: ClientIdentity) async throws -> (ShowResult, String) {
        _ = try register(client)
        guard let record = try store.thread(id: arguments.thread.number), record.deletedAt == nil,
              let facts = try store.facts(stackID: record.stackID),
              let thread = facts.threads.first(where: { $0.id == record.id }),
              !facts.sentComments(of: thread).isEmpty else {
            throw EyeballsError(.unknownThread, "\(arguments.thread) is not a thread in Eyeballs.", hint: "Check the ID with eyeballs inbox or eyeballs threads.")
        }
        let reviewer = await reviewerName(for: facts.repo)
        let repository = try? await repository(for: facts.repo)
        let anchor = facts.newestAnchor(of: thread)
        let context = arguments.context ?? 5

        var code: [CodeLine] = []
        if let anchor, let start = anchor.startLine, let end = anchor.endLine, let blob = anchor.blob.flatMap(ObjectID.init),
           let repository, let text = try? await repository.fileText(blob) {
            let first = max(1, start - context)
            let last = min(text.lineCount, end + context)
            if first <= last {
                for number in first...last {
                    code.append(CodeLine(line: number, text: Self.display(text.lines[number - 1]), covered: (start...end).contains(number)))
                }
            }
        }
        var original: [String]?
        if thread.subject == .line, anchor?.startLine == nil, let covered = facts.origin(of: thread)?.coveredText {
            original = covered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }

        let comments = facts.sentComments(of: thread).map { comment in
            let ranges = (comment.atRanges ?? []).map { LineSpan(path: $0.path, start: $0.start, end: $0.end) }
            let name = comment.author == .agent ? "You" : reviewer.startingSentence
            return ShownComment(id: CommentID(comment.id), author: comment.author == .agent ? .agent : .human, name: name,
                                replyStatus: comment.replyStatus?.wire, revision: facts.number(ofRevision: comment.revisionID),
                                body: comment.body, at: ranges, createdAt: Self.isoTime(comment.sentAt ?? comment.createdAt))
        }
        let steps = (facts.anchors[thread.id] ?? []).map {
            AnchorStep(revision: facts.number(ofRevision: $0.revisionID), start: $0.startLine, end: $0.endLine, state: $0.state.wire)
        }
        let layer = facts.layers[thread.layerID]
        let checkouts = await worktreeBranches(repository)
        let agentWorktree = try? await self.repository(at: URL(fileURLWithPath: client.cwd, isDirectory: true)).workTree?.path
        let checkout = layer.flatMap { checkouts[$0.branch] }.flatMap { $0 == agentWorktree ? nil : $0 }
        let snapshot = anchor.flatMap { facts.snapshots[$0.snapshotID] }
        let shown = ShownThread(
            id: ThreadID(thread.id), status: thread.status.wire, state: Self.stateLabel(facts.progress(of: thread).state),
            subject: thread.subject.wire, side: thread.side?.wire,
            layer: ThreadLayer(position: layer?.position ?? 0, branch: layer?.branch ?? "", pr: layer?.prNumber, checkout: checkout),
            path: anchor?.path, start: anchor?.startLine, end: anchor?.endLine, commit: snapshot.map { String($0.headSHA.prefix(7)) },
            anchor: Self.shownState(anchor), revision: facts.latestRevision?.number ?? 0, code: code, original: original,
            comments: comments, anchors: steps)
        let result = ShowResult(stack: summary(of: facts.stack, repo: facts.repo), thread: shown)
        return (result, ShowText.render(shown, label: stackLabel(facts.stack)))
    }

    static func stateLabel(_ state: DerivedThreadState) -> String {
        ThreadState(state).label
    }

    // MARK: threads

    /// `eyeballs threads`: one line per thread in the caller's stack, or in every stack it drives.
    func threads(_ arguments: ThreadsArguments, client: ClientIdentity) async throws -> (ThreadsResult, String) {
        let session = try register(client)
        var stacks: [StackRecord] = []
        if let here = try await knownStack(nil, client: client, session: session) {
            stacks = [here]
        } else {
            stacks = try store.activeStacks()
        }
        var lines: [ThreadLine] = []
        var reviewers: [Int: ReviewerName] = [:]
        for stack in stacks {
            let facts = try facts(stack.id)
            reviewers[stack.id] = await reviewerName(for: facts.repo)
            for thread in facts.threads {
                let sent = facts.sentComments(of: thread)
                guard !sent.isEmpty, arguments.filter == .all || thread.status == .open else { continue }
                let progress = facts.progress(of: thread)
                let anchor = facts.newestAnchor(of: thread)
                let layer = facts.layers[thread.layerID]
                let waitingOn: WaitingOn = progress.waitsOnAgent ? .agent : progress.state.needsYou ? .reviewer : .nobody
                lines.append(ThreadLine(
                    id: ThreadID(thread.id), stack: StackID(stack.id),
                    layer: ThreadLayer(position: layer?.position ?? 0, branch: layer?.branch ?? "", pr: layer?.prNumber),
                    path: anchor?.path, start: anchor?.startLine, end: anchor?.endLine, status: thread.status.wire,
                    waitingOn: waitingOn, state: Self.stateLabel(progress.state),
                    lastReply: sent.last(where: { $0.author == .agent })?.replyStatus?.wire))
            }
        }
        let text = ThreadsText.render(lines) { reviewers[$0.stack.number] ?? ReviewerName(name: nil) }
        return (ThreadsResult(threads: lines), text)
    }

    // MARK: status

    /// `eyeballs status`: one line for the agent, the skill and hooks. It never fails.
    func status(_ arguments: StatusArguments, client: ClientIdentity) async -> (StatusResult, String) {
        do {
            let session = try register(client)
            var stacks = try session.map { try store.stacksDriven(bySession: $0.id) } ?? []
            if let here = try? await knownStack(nil, client: client, session: nil), !stacks.contains(where: { $0.id == here.id }) {
                stacks.append(here)
            }
            var entries: [StatusStack] = []
            var lines: [String] = []
            for stack in stacks {
                let facts = try facts(stack.id)
                let waiting = try store.threadsWaitingOnAgent(stackID: stack.id)
                let needsReply = waiting.filter(\.wasShown).map { ThreadID($0.thread.id) }
                let review = facts.lastSubmittedReview
                let entry = StatusStack(
                    stack: summary(of: stack, repo: facts.repo), revision: facts.latestRevision?.number,
                    driver: session != nil && stack.driverSession == session?.id, review: review?.id, needsReply: needsReply,
                    waitingOnReviewer: facts.threads.filter { facts.progress(of: $0).state.needsYou }.count)
                entries.append(entry)
                lines.append(statusLine(entry, facts: facts, undelivered: review?.status == .submitted))
            }
            let listening = listening(Self.listener(for: client, session: session))
            let result = StatusResult(app: .running, stacks: entries, listening: listening)
            guard !lines.isEmpty else { return (result, "Eyeballs: nothing open for this session.") }
            let listeningText = "Listening: \(listening.isEmpty ? "nothing" : AgentText.list(listening.map(\.rawValue)))."
            if arguments.brief {
                let first = entries.firstIndex(where: \.driver) ?? 0
                return (result, "\(lines[first]) \(listeningText)")
            }
            return (result, (lines + [listeningText]).joined(separator: "\n"))
        } catch {
            Log.server.error("Status could not be read: \(String(describing: error), privacy: .public)")
            return (StatusResult(app: .running), "Eyeballs: running, but this status could not be read.")
        }
    }

    private func statusLine(_ entry: StatusStack, facts: StackFacts, undelivered: Bool) -> String {
        let label = stackLabel(facts.stack)
        let at = entry.revision.map { " at r\($0)" } ?? ""
        guard entry.driver else { return "Eyeballs: another session drives \(label)\(at)." }
        var line = "Eyeballs: you drive \(label)\(at)."
        if undelivered, let review = entry.review {
            line += " Review \(review) is waiting: run eyeballs inbox."
        } else if !entry.needsReply.isEmpty {
            let prefix = entry.review.map { "Review \($0): " } ?? ""
            line += " \(prefix)\(AgentText.count(entry.needsReply.count, "thread")) still need\(entry.needsReply.count == 1 ? "s" : "") your reply (\(AgentText.list(entry.needsReply.map(\.description))))."
        } else {
            line += " Nothing waits on you."
        }
        return line
    }

    // MARK: attach

    /// `eyeballs attach`: the caller takes over as the stack's driver.
    func attach(_ arguments: AttachArguments, client: ClientIdentity) async throws -> (AttachResult, String) {
        try await oneAtATime.run {
            guard let session = try self.register(client) else {
                throw EyeballsError.badInput("eyeballs attach cannot tell which agent session to make the driver.",
                                             hint: "Run it from Claude Code, or pass --session.")
            }
            guard let stack = try await self.knownStack(arguments.stack, client: client, session: session) else {
                throw EyeballsError(.noStack, "There is no stack here to attach to.", hint: "Run eyeballs review first, or pass --stack.")
            }
            let tookOver = try self.takeDriverRole(of: stack, for: session)
            let facts = try self.facts(stack.id)
            let waiting = try self.store.threadsWaitingOnAgent(stackID: stack.id)
            let next: NextStep = waiting.isEmpty ? .runWaitInBackground : .runInbox
            self.notify(.stack(stack.id))
            let result = AttachResult(stack: self.summary(of: stack, repo: facts.repo), revision: facts.latestRevision?.number,
                                      tookOver: tookOver, next: next)
            let at = facts.latestRevision.map { " at r\($0.number)" } ?? ""
            var text = "You now drive \(self.stackLabel(stack))\(at)."
            if tookOver { text += " Another session drove it before; its waits end." }
            text += "\n" + (next == .runInbox ? "Next: run `eyeballs inbox`." : ReviewText.nextLine(.runWaitInBackground))
            return (result, text)
        }
    }
}

extension ThreadState {
    /// The window's state for the store's derived state.
    init(_ state: DerivedThreadState) {
        switch state {
        case .resolved: self = .resolved
        case .draft: self = .draft
        case .agentAsks: self = .agentAsks
        case .checkTheFix: self = .checkTheFix
        case .agentDeclined: self = .agentDeclined
        case .waitingOnAgent: self = .waitingOnAgent
        }
    }
}
