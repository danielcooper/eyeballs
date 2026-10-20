import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation

extension ReviewService {
    // MARK: inbox

    /// `eyeballs inbox`: every thread that waits on the agent, bottom layer first.
    ///
    /// Threads shown before are included and labelled. Showing a comment for the first time sets
    /// its `delivered_at`, which only stops repeat wake-ups. `--peek` changes nothing.
    func inbox(_ arguments: InboxArguments, client: ClientIdentity) async throws -> (InboxResult, String) {
        try await oneAtATime.run { try await self.inboxNow(arguments, client: client) }
    }

    private func inboxNow(_ arguments: InboxArguments, client: ClientIdentity) async throws -> (InboxResult, String) {
        let session = try register(client)
        guard let stack = try await knownStack(arguments.stack, client: client, session: session) else {
            return (InboxResult(status: .nothing, stack: nil, revision: nil, reviewer: ReviewerName(name: nil).inSentence, next: .runWaitInBackground),
                    InboxText.nothing)
        }
        let facts = try facts(stack.id)
        let reviewer = await reviewerName(for: facts.repo)
        let summary = summary(of: stack, repo: facts.repo)
        let revision = facts.latestRevision?.number ?? 0
        func answer(_ status: InboxStatus, _ text: String, next: NextStep) -> (InboxResult, String) {
            (InboxResult(status: status, stack: summary, revision: revision, reviewer: reviewer.inSentence, next: next), text)
        }

        if case .other = try claimIfFree(stack, by: session) {
            return answer(.notDriver, InboxText.notDriver(label: stackLabel(stack)), next: .stop)
        }
        if stack.state == .archived {
            return answer(.closed, InboxText.closed(reviewer: reviewer, label: stackLabel(stack)), next: .stop)
        }

        let waiting = try store.threadsWaitingOnAgent(stackID: stack.id)
        let undelivered = facts.reviews.filter { $0.status == .submitted }.reversed()
        if waiting.isEmpty {
            if let approval = facts.lastSubmittedReview, approval.verdict == .approved, approval.revisionID == facts.latestRevision?.id {
                if !arguments.peek { try deliver(reviews: [approval.id], comments: [], to: session, stack: stack.id) }
                return answer(.approved, InboxText.approved(reviewer: reviewer, name: stack.name, revision: revision), next: .stop)
            }
            let summaries = undelivered.filter { !$0.body.isEmpty }
            guard !summaries.isEmpty else {
                if !arguments.peek { try deliver(reviews: undelivered.map(\.id), comments: [], to: session, stack: stack.id) }
                return answer(.nothing, InboxText.nothing, next: .runWaitInBackground)
            }
        }

        let repository = try? await repository(for: facts.repo)
        let checkouts = await worktreeBranches(repository)
        let agentWorktree = try? await self.repository(at: URL(fileURLWithPath: client.cwd, isDirectory: true)).workTree?.path
        var threads: [PacketThread] = []
        for thread in waiting {
            if let packet = await packetThread(thread, facts: facts, repository: repository, checkouts: checkouts, agentWorktree: agentWorktree) {
                threads.append(packet)
            }
        }
        let reviewIDs = Set(threads.compactMap(\.wire.review)).union(undelivered.filter { !$0.body.isEmpty }.map(\.id))
        let reviews = facts.reviews.filter { reviewIDs.contains($0.id) }.reversed().map(Self.inboxReview)
        let packet = InboxPacket(reviewer: reviewer, stackLabel: stackLabel(stack), revision: revision, reviews: Array(reviews), threads: threads)
        let page = packet.page(arguments.page)

        if !arguments.peek {
            let shownIDs = Set(page.threads.map(\.wire.id.number))
            let comments = waiting.filter { shownIDs.contains($0.thread.id) }.flatMap(\.unanswered).map(\.id)
            // markDelivered reaches a review only through its comments, so a review without waiting threads is marked here.
            let withoutThreads = undelivered.filter { review in !waiting.contains { $0.unanswered.contains { $0.reviewID == review.id } } }
            try deliver(reviews: arguments.page == 1 ? withoutThreads.map(\.id) : [], comments: comments, to: session, stack: stack.id)
        }
        let pageReviews = Set(page.threads.compactMap(\.wire.review))
        let shownReviews = arguments.page == 1 ? packet.reviews : packet.reviews.filter { pageReviews.contains($0.id) }
        let result = InboxResult(
            status: .threads, stack: summary, revision: revision, reviewer: reviewer.inSentence, reviews: shownReviews,
            threads: page.threads.map(\.wire), more: page.more, nextPage: page.nextPage, next: .replyThenReview)
        return (result, page.text)
    }

    /// Marks what `inbox` showed, and tells the window, whose review bar says "Delivered".
    private func deliver(reviews: [Int], comments: [Int], to session: AgentSessionRecord?, stack: Int) throws {
        try store.markDelivered(commentIDs: comments, to: session?.id)
        try store.markReviewsDelivered(reviewIDs: reviews, to: session?.id)
        if !reviews.isEmpty || !comments.isEmpty { notify(.stack(stack)) }
    }

    private static func inboxReview(_ review: ReviewRecord) -> InboxReview {
        InboxReview(id: review.id, verdict: (review.verdict ?? .comment).wire, body: review.body,
                    submittedAt: Self.isoTime(review.submittedAt ?? review.createdAt))
    }

    static func isoTime(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
    }

    private func packetThread(_ waiting: WaitingThread, facts: StackFacts, repository: GitRepository?,
                              checkouts: [String: String], agentWorktree: String?) async -> PacketThread? {
        let thread = waiting.thread
        let anchor = waiting.anchor
        guard let newest = waiting.unanswered.last else { return nil }
        let history = waiting.comments.filter { $0.id != newest.id }.map { comment in
            let cut = AgentText.cut(comment.body, to: TextBudget.historyComment)
            return HistoryComment(id: CommentID(comment.id), author: comment.author == .agent ? .agent : .human,
                                  replyStatus: comment.replyStatus?.wire, revision: facts.number(ofRevision: comment.revisionID),
                                  body: cut.text, truncated: cut.truncated)
        }

        var code: [String] = []
        var hidden = 0
        if let anchor, let start = anchor.startLine, let end = anchor.endLine, let blob = anchor.blob.flatMap(ObjectID.init),
           let repository, let text = try? await repository.fileText(blob), let lines = text.lines(in: start...end) {
            code = Array(lines.prefix(TextBudget.codeLinesPerThread)).map(Self.display)
            hidden = max(0, lines.count - TextBudget.codeLinesPerThread)
        }

        var original: [String]?
        var originalStart: Int?
        let lost = anchor.map { $0.state == .outdated || $0.state == .gone || $0.state == .changed } ?? false
        if thread.subject == .line, lost, let origin = facts.origin(of: thread), let covered = origin.coveredText {
            original = Array(covered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).prefix(TextBudget.codeLinesPerThread))
            originalStart = origin.startLine
        }

        var movedFrom: String?
        if let anchor, anchor.state == .moved, let previous = facts.goodAnchor(before: anchor, of: thread),
           let start = previous.startLine, let end = previous.endLine {
            movedFrom = "\(AgentText.range(start, end)) since r\(facts.number(ofRevision: previous.revisionID))"
        }

        let layer = waiting.layer
        let checkout = checkouts[layer.branch].flatMap { $0 == agentWorktree ? nil : $0 }
        let snapshot = anchor.flatMap { facts.snapshots[$0.snapshotID] }
        let wire = InboxThread(
            id: ThreadID(thread.id), kind: waiting.kind.wire, review: newest.reviewID, shownBefore: waiting.shownBefore,
            layer: ThreadLayer(position: layer.position, branch: layer.branch, pr: layer.prNumber, checkout: checkout),
            subject: thread.subject.wire, side: thread.side?.wire, path: anchor?.path, start: anchor?.startLine, end: anchor?.endLine,
            commit: snapshot.map { String($0.headSHA.prefix(7)) }, anchor: Self.shownState(anchor),
            commentedOn: facts.number(ofRevision: newest.revisionID), code: code, original: original, history: history,
            comment: InboxComment(id: CommentID(newest.id), body: newest.body))
        return PacketThread(wire: wire, movedFrom: movedFrom, hiddenCodeLines: hidden, originalStart: originalStart)
    }

    /// The anchor's state as packets name it. A thread still on the lines it was written on is `current`.
    static func shownState(_ anchor: AnchorRecord?) -> WireAnchorState {
        guard let anchor, anchor.state != .original else { return .current }
        return anchor.state.wire
    }

    static func display(_ line: [UInt8]) -> String {
        String(decoding: line.last == 0x0D ? Array(line.dropLast()) : line, as: UTF8.self)
    }

    /// Which branch each worktree has checked out, for the packet's `checkout:` line.
    func worktreeBranches(_ repository: GitRepository?) async -> [String: String] {
        guard let repository, let listing = try? await repository.git.run(["worktree", "list", "--porcelain"]) else { return [:] }
        var branches: [String: String] = [:]
        var path: String?
        for line in listing.text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let path {
                branches[String(line.dropFirst("branch refs/heads/".count))] = path
            }
        }
        return branches
    }

    // MARK: wait and watch

    /// `eyeballs wait`: answers at once when something already waits, else keeps the connection
    /// open for the next event routed to the caller's Claude process.
    func wait(_ arguments: WaitArguments, client: ClientIdentity) async throws -> HandlerOutcome {
        try await oneAtATime.run { try await self.waitNow(arguments, client: client) }
    }

    private func waitNow(_ arguments: WaitArguments, client: ClientIdentity) async throws -> HandlerOutcome {
        let session = try register(client)
        guard let listener = Self.listener(for: client, session: session) else {
            throw EyeballsError.badInput("eyeballs wait cannot tell which agent session it belongs to.",
                                         hint: "Run it from Claude Code, or pass --session.")
        }
        let named = try await knownStack(arguments.stack, client: client, session: session)
        let stacks = try named.map { [$0] } ?? session.map { try store.stacksDriven(bySession: $0.id) } ?? []
        for stack in stacks {
            if case .other = try claimIfFree(stack, by: session) {
                guard named != nil else { continue }
                let event = AgentEvents.notDriver(stack: stack.id, label: stackLabel(stack))
                return .respond(.success(result: event.result, text: event.text))
            }
            if let event = try await pendingEvent(stack) {
                return .respond(.success(result: event.result, text: event.text))
            }
        }
        let stackID = named.map { StackID($0.id) }
        let timeout = arguments.timeoutSeconds.map { seconds in
            StreamTimeout(after: .seconds(seconds), event: WaitEvent.timeoutEvent(after: .seconds(seconds), stack: stackID))
        }
        return .stream(StreamRequest(mode: .wait, listener: listener, stack: stackID, timeout: timeout))
    }

    /// The event for something `inbox` has not shown yet: a submitted review, or a sent comment.
    func pendingEvent(_ stack: StackRecord) async throws -> StreamEvent? {
        let facts = try facts(stack.id)
        if stack.state == .archived {
            return AgentEvents.stackClosed(stack: stack.id, label: stackLabel(stack), reviewer: await reviewerName(for: facts.repo))
        }
        let revision = facts.latestRevision?.number ?? 0
        if let review = facts.reviews.last(where: { $0.status == .submitted }) {
            return AgentEvents.reviewSubmitted(
                review: review.id, verdict: ReviewVerdictWords(wire: (review.verdict ?? .comment).wire), stack: stack.id, name: stack.name,
                revision: revision, reviewer: await reviewerName(for: facts.repo), threads: threadCount(of: review, in: facts))
        }
        let waiting = try store.threadsWaitingOnAgent(stackID: stack.id)
        if let fresh = waiting.first(where: { $0.unanswered.contains { $0.deliveredAt == nil } }) {
            return AgentEvents.commentSent(thread: fresh.thread.id, stack: stack.id, name: stack.name, revision: revision,
                                           reviewer: await reviewerName(for: facts.repo))
        }
        return nil
    }

    func threadCount(of review: ReviewRecord, in facts: StackFacts) -> Int {
        facts.threads.filter { thread in (facts.comments[thread.id] ?? []).contains { $0.reviewID == review.id } }.count
    }

    /// `eyeballs watch`: streams every event for the caller's Claude process. A monitor without
    /// `CLAUDE_PID` is matched to a registered PID among its ancestors.
    func watch(client: ClientIdentity) async throws -> HandlerOutcome {
        let session = try register(client)
        var listener = Self.listener(for: client, session: session)
        if listener == nil, let process = try claudeProcess(amongAncestors: client.ancestors) {
            listener = .claudeProcess(process)
        }
        guard let listener else {
            throw EyeballsError.badInput("eyeballs watch cannot tell which Claude Code session it belongs to yet.",
                                         hint: "It tries again shortly, once the session has run an eyeballs command.")
        }
        return .stream(StreamRequest(mode: .watch, listener: listener))
    }

    /// Catches a submit that lands between a `wait`'s check and the moment its connection starts
    /// streaming: each new `wait` gets any event that is still waiting. Also tells the window.
    func followLiveStreams(_ changes: AsyncStream<[LiveStream]>) async {
        var known = Set<Int>()
        for await streams in changes {
            notify(.listeners(streams))
            let fresh = streams.filter { $0.mode == .wait && !known.contains($0.connection) }
            known = Set(streams.map(\.connection))
            for stream in fresh {
                guard let stackID = stream.stack?.number,
                      let stack = try? store.stack(id: stackID),
                      let event = try? await pendingEvent(stack),
                      liveStreams.contains(where: { $0.connection == stream.connection }) else { continue }
                broadcast(event, to: stream.listener)
            }
        }
    }

    // MARK: Finding a stack Eyeballs knows

    /// The stack a command means: the one it names, else one the caller's session drives (the one
    /// holding the branch checked out in the caller's folder, if any, else the newest), else the
    /// one holding that branch.
    func knownStack(_ reference: StackReference?, client: ClientIdentity, session: AgentSessionRecord?) async throws -> StackRecord? {
        switch reference {
        case .id(let id)?:
            guard let stack = try store.stack(id: id.number) else {
                throw EyeballsError(.noStack, "No stack \(id) exists in Eyeballs.", hint: "Run eyeballs status to see the stacks you drive.")
            }
            return stack
        case .branch(let branch)?:
            if let repository = try? await repository(at: URL(fileURLWithPath: client.cwd, isDirectory: true)),
               let repo = try store.repo(commonDir: repository.commonDirectory.path),
               let stack = try store.activeStacks(containing: branch, repoID: repo.id).first {
                return stack
            }
            throw EyeballsError(.noStack, "No stack in Eyeballs has that branch as a layer.", hint: "Run eyeballs review to open it.")
        case nil:
            var stacksHoldingBranch: [StackRecord] = []
            if let repository = try? await repository(at: URL(fileURLWithPath: client.cwd, isDirectory: true)),
               let repo = try store.repo(commonDir: repository.commonDirectory.path),
               let branch = try? await repository.currentBranch() {
                stacksHoldingBranch = try store.activeStacks(containing: branch, repoID: repo.id)
            }
            let driven = try session.map { try store.stacksDriven(bySession: $0.id) } ?? []
            if let both = driven.first(where: { stack in stacksHoldingBranch.contains { $0.id == stack.id } }) { return both }
            return driven.first ?? stacksHoldingBranch.first
        }
    }
}
