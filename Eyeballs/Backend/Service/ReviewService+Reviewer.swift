import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation

extension ReviewService {
    // MARK: What the window shows

    /// The sidebar: every repo with an active stack, and each stack's layers at the revision you view.
    ///
    /// - Parameter viewing: the revision ID you view, by stack ID. A stack not in it shows its newest revision.
    func overview(viewing: [Int: Int]) async throws -> Overview {
        var repositories: [Int: RepositoryItem] = [:]
        var order: [Int] = []
        var newest: [Int: NewestRevision] = [:]
        for stack in try store.activeStacks() {
            guard let facts = try store.facts(stackID: stack.id) else { continue }
            let revisionID = viewing[stack.id] ?? facts.latestRevision?.id
            if let latest = facts.latestRevision {
                newest[stack.id] = NewestRevision(id: latest.id, number: latest.number, byAgent: latest.trigger == .agentSubmit)
            }
            let item = try stackItem(facts, revisionID: revisionID)
            if repositories[facts.repo.id] == nil {
                let path = Self.workTreePath(of: facts.repo)
                repositories[facts.repo.id] = RepositoryItem(id: facts.repo.id, name: URL(fileURLWithPath: path).lastPathComponent, path: path, stacks: [])
                order.append(facts.repo.id)
            }
            repositories[facts.repo.id]?.stacks.append(item)
        }
        return Overview(repositories: order.sorted().compactMap { repositories[$0] }, newestRevisions: newest)
    }

    struct Overview: Sendable {
        var repositories: [RepositoryItem]
        /// Each active stack's newest revision, by stack ID.
        var newestRevisions: [Int: NewestRevision]
    }

    struct NewestRevision: Sendable, Hashable {
        var id: Int
        var number: Int
        /// True when the agent's `eyeballs review` made it, false for a snapshot you took.
        var byAgent: Bool
    }

    private func stackItem(_ facts: StackFacts, revisionID: Int?) throws -> StackItem {
        let snapshotIDs = revisionID.flatMap { facts.revisionSnapshots[$0] } ?? [:]
        let files = try store.files(ofSnapshots: Array(snapshotIDs.values))
        let threads = facts.threads.filter { !(facts.comments[$0.id] ?? []).isEmpty }
        let layers = facts.activeLayers.map { layer -> LayerItem in
            let snapshot = snapshotIDs[layer.id].flatMap { facts.snapshots[$0] }
            let changed = snapshot.flatMap { files[$0.id] } ?? []
            let layerThreads = threads.filter { $0.layerID == layer.id }
            var status = LayerStatus.ready
            if let snapshot, snapshot.baseSHA == snapshot.headSHA {
                status = .empty
            } else if let snapshot, snapshot.baseRule != .parentTip {
                status = .needsRestack
            }
            return LayerItem(
                id: layer.id, position: layer.position, branch: layer.branch, prNumber: layer.prNumber, fileCount: changed.count,
                additions: changed.reduce(0) { $0 + ($1.additions ?? 0) }, deletions: changed.reduce(0) { $0 + ($1.deletions ?? 0) },
                openThreadCount: layerThreads.filter { $0.status == .open }.count, status: status,
                needsYouCount: layerThreads.filter { windowState(of: $0, facts: facts).needsYou }.count)
        }
        return StackItem(
            id: facts.stack.id, name: facts.stack.name, trunk: facts.stack.trunkBranch,
            revision: revisionID.map { facts.number(ofRevision: $0) },
            layers: layers, openThreadCount: layers.reduce(0) { $0 + $1.openThreadCount },
            needsYouCount: layers.reduce(0) { $0 + $1.needsYouCount })
    }

    /// The threads, review bar and agent facts of one stack, at the revision you view.
    func stackContent(stackID: Int, revisionID: Int?) async throws -> StackContent {
        let facts = try facts(stackID)
        let reviewer = await reviewerName(for: facts.repo)
        let revision = revisionID ?? facts.latestRevision?.id ?? 0
        var byLayer: [Int: [ThreadItem]] = [:]
        for thread in facts.threads {
            guard let item = threadItem(thread, facts: facts, revisionID: revision, reviewer: reviewer) else { continue }
            byLayer[thread.layerID, default: []].append(item)
        }
        var review = PendingReview(pendingCommentCount: facts.pendingComments.count)
        if let submitted = facts.lastSubmittedReview {
            review.lastSubmitted = SubmittedReview(
                number: submitted.id, verdict: Verdict(submitted.verdict ?? .comment), date: submitted.submittedAt ?? submitted.createdAt,
                deliveredAt: submitted.deliveredAt)
        }
        var progress: AgentProgress?
        if let submitted = facts.lastSubmittedReview, submitted.status == .delivered {
            let threads = facts.threads.filter { thread in (facts.comments[thread.id] ?? []).contains { $0.reviewID == submitted.id } }
            let replied = threads.filter { !facts.progress(of: $0).waitsOnAgent }.count
            progress = AgentProgress(review: submitted.id, replied: replied, total: threads.count)
        }
        let driver = facts.driver
        return StackContent(
            stackID: stackID, threadsByLayer: byLayer, review: review,
            driverListener: driver.map(Self.listener(for:)), agentName: driver.flatMap { Self.agentName($0.agent) }, progress: progress)
    }

    struct StackContent: Sendable {
        var stackID: Int
        var threadsByLayer: [Int: [ThreadItem]]
        /// The review bar's facts. The summary you are typing comes from the drafts instead.
        var review: PendingReview
        /// Where the driver's events go, for the status pill.
        var driverListener: ListenerKey?
        var agentName: String?
        var progress: AgentProgress?
    }

    /// How far the agent is through the newest review it has read.
    struct AgentProgress: Sendable, Hashable {
        var review: Int
        var replied: Int
        var total: Int
    }

    /// "Claude" for Claude Code, or the agent's own name. Nil when nothing names the agent.
    static func agentName(_ agent: AgentKind) -> String? {
        switch agent {
        case .claude: "Claude"
        case .other: nil
        case .unknown(let name): name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// One thread as the window shows it, or nil for a thread with no comments left.
    func threadItem(_ thread: ThreadRecord, facts: StackFacts, revisionID: Int, reviewer: ReviewerName) -> ThreadItem? {
        let comments = facts.comments[thread.id] ?? []
        guard !comments.isEmpty else { return nil }
        let items = comments.map { comment in
            CommentItem(
                id: comment.id,
                author: comment.author == .agent
                    ? .agent(name: comment.agentSession.flatMap { facts.sessions[$0] }.flatMap { Self.agentName($0.agent) } ?? "Agent")
                    : .you(name: reviewer.name ?? "You"),
                replyStatus: comment.replyStatus.flatMap(ReplyStatus.init), body: comment.body, date: comment.sentAt ?? comment.createdAt,
                isPending: comment.author == .human && comment.sentAt == nil, isEdited: facts.editedCommentIDs.contains(comment.id),
                fixRanges: (comment.atRanges ?? []).map { LineRange(path: $0.path, side: .head, start: $0.start, end: $0.end) })
        }
        let origin = facts.origin(of: thread)
        let anchorAtRevision = facts.anchor(of: thread, at: revisionID)
        let anchor = anchorAtRevision ?? origin
        var place: ThreadAnchor = .layer
        var note: String?
        var original: [String] = []
        if let anchor {
            switch thread.subject {
            case .layer:
                place = .layer
            case .file:
                place = (anchor.path ?? origin?.path).map { .file(path: $0) } ?? .layer
            default:
                if let path = anchor.path, let start = anchor.startLine, let end = anchor.endLine {
                    place = .lines(LineRange(path: path, side: thread.side == .base ? .base : .head, start: start, end: end))
                } else {
                    place = (anchor.path ?? origin?.path).map { .file(path: $0) } ?? .layer
                    original = (origin?.coveredText ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                }
            }
            note = anchorAtRevision == nil
                ? "Written on revision \(facts.number(ofRevision: anchor.revisionID))."
                : anchorNote(anchor, of: thread, facts: facts)
        }
        return ThreadItem(id: thread.id, anchor: place, comments: items, isResolved: thread.status == .resolved,
                          state: windowState(of: thread, facts: facts), anchorNote: note, originalLines: original)
    }

    /// The window's state: the design's derived state, except that a thread whose newest comment
    /// is your unsent reply shows as a draft, because you have already answered it.
    func windowState(of thread: ThreadRecord, facts: StackFacts) -> ThreadState {
        let state = ThreadState(facts.progress(of: thread).state)
        guard state != .resolved, let last = facts.comments[thread.id]?.last, last.author == .human, last.sentAt == nil else { return state }
        return .draft
    }

    private func anchorNote(_ anchor: AnchorRecord, of thread: ThreadRecord, facts: StackFacts) -> String? {
        let number = facts.number(ofRevision: anchor.revisionID)
        switch anchor.state {
        case .moved:
            guard let previous = facts.goodAnchor(before: anchor, of: thread), let line = previous.startLine else { return nil }
            return "Moved from line \(line) in revision \(facts.number(ofRevision: previous.revisionID))"
        case .outdated:
            return anchor.nearLine.map { "Was near line \($0) in revision \(number)." } ?? "The lines changed in revision \(number)."
        case .gone:
            return anchor.path == nil && thread.subject != .layer
                ? "Gone: the file was deleted in revision \(number)."
                : "Gone: the layer left the stack in revision \(number)."
        default:
            return nil
        }
    }

    /// One layer's commits and files at a revision, read from git once per snapshot.
    /// Nil when the layer has no snapshot yet.
    func layerDiff(stackID: Int, layerID: Int, revisionID: Int?) async throws -> LayerDiff? {
        let facts = try facts(stackID)
        let snapshot = revisionID.flatMap { facts.snapshot(layerID: layerID, revisionID: $0) }
            ?? facts.latestRevision.flatMap { facts.snapshot(layerID: layerID, revisionID: $0.id) }
        guard let snapshot else { return nil }
        if let cached = layerDiffs.diff(forSnapshot: snapshot.id) { return cached }

        let repository = try await repository(for: facts.repo)
        let base = try Self.commit(of: snapshot, side: .base)
        let head = try Self.commit(of: snapshot, side: .head)
        let commits = try await repository.commits(from: base, to: head).map {
            CommitItem(sha: $0.sha.hex, subject: $0.subject, author: $0.author, date: $0.date)
        }
        var files: [FileItem] = []
        for file in try await repository.changedFiles(from: base, to: head) {
            files.append(try await fileItem(file, in: repository))
        }
        let diff = LayerDiff(commits: commits, files: files)
        layerDiffs.store(diff, forSnapshot: snapshot.id)
        return diff
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "ico"]

    private func fileItem(_ file: DiffFile, in repository: GitRepository) async throws -> FileItem {
        let texts = try await repository.fileTexts(for: file)
        var item = FileItem(
            path: file.path.string,
            oldPath: file.change == .renamed || file.change == .copied ? file.oldPath?.string : nil,
            change: FileChange(file.change), additions: file.additions, deletions: file.deletions, isBinary: file.isBinary,
            hunks: file.hunks.map { hunk in
                HunkItem(header: hunk.header, oldStart: hunk.oldStart, oldCount: hunk.oldCount, newStart: hunk.newStart, newCount: hunk.newCount,
                         lines: hunk.lines.map { LineItem(kind: LineKind($0.kind), oldNumber: $0.oldNumber, newNumber: $0.newNumber, text: $0.text) })
            },
            newLines: texts.new?.strings ?? [], oldLines: texts.old?.strings ?? [])
        if file.isBinary, Self.imageExtensions.contains(URL(fileURLWithPath: item.path).pathExtension.lowercased()) {
            if let blob = file.newBlob, !blob.isZero { item.newImage = try? await repository.blobs.blob(blob) }
            if let blob = file.oldBlob, !blob.isZero { item.oldImage = try? await repository.blobs.blob(blob) }
        }
        return item
    }

    // MARK: What you do in the window

    /// Opens a thread where you clicked. Send now first takes a snapshot when the branches moved,
    /// then ports the thread to the newest revision and wakes the agent (fix 13).
    func addComment(_ body: String, at anchor: ThreadAnchor, layerID: Int, viewing revisionID: Int, sendNow: Bool) async throws {
        try await oneAtATime.run {
            _ = try await self.addCommentNow(body, at: anchor, layerID: layerID, viewing: revisionID, sendNow: sendNow)
        }
    }

    func addCommentNow(_ body: String, at anchor: ThreadAnchor, layerID: Int, viewing revisionID: Int, sendNow: Bool) async throws
        -> (thread: ThreadRecord, comment: CommentRecord) {
        guard let stackID = try store.layer(id: layerID)?.stackID else {
            throw EyeballsError(.badInput, "That layer is no longer in Eyeballs.")
        }
        let newest = sendNow ? try await snapshotIfMoved(stackID) : nil
        let facts = try facts(stackID)
        let origin = try await originAnchor(for: anchor, layerID: layerID, revisionID: revisionID, facts: facts)
        let created = try store.createThread(subject: origin.subject, side: origin.side, origin: origin.anchor, body: body,
                                             delivery: sendNow ? .sendNow : .addToReview)
        if let newest {
            try await portThread(created.thread.id, stackID: stackID, to: newest)
            await announceComment(on: created.thread.id, stackID: stackID)
        }
        notify(.stack(stackID))
        return (created.thread, created.comment)
    }

    /// Adds your reply to a thread, to the review or sent at once.
    func reply(_ body: String, to threadID: Int, sendNow: Bool) async throws {
        try await oneAtATime.run { _ = try await self.replyNow(body, to: threadID, sendNow: sendNow) }
    }

    func replyNow(_ body: String, to threadID: Int, sendNow: Bool) async throws -> CommentRecord {
        guard let thread = try store.thread(id: threadID) else { throw EyeballsError(.unknownThread, "That thread is no longer in Eyeballs.") }
        let newest = sendNow ? try await snapshotIfMoved(thread.stackID) : nil
        let comment = try store.addComment(threadID: threadID, body: body, delivery: sendNow ? .sendNow : .addToReview)
        if let newest {
            try await portThread(threadID, stackID: thread.stackID, to: newest)
            await announceComment(on: threadID, stackID: thread.stackID)
        }
        notify(.stack(thread.stackID))
        return comment
    }

    func editComment(_ commentID: Int, body: String) async throws {
        try await oneAtATime.run {
            let comment = try self.store.editComment(commentID: commentID, body: body)
            try self.notifyStack(ofThread: comment.threadID)
        }
    }

    func deleteComment(_ commentID: Int) async throws {
        try await oneAtATime.run {
            let threadID = try self.store.reader.read { try CommentRecord.fetchOne($0, id: commentID)?.threadID }
            try self.store.deleteComment(commentID: commentID)
            if let threadID { try self.notifyStack(ofThread: threadID) }
        }
    }

    func deleteThread(_ threadID: Int) async throws {
        try await oneAtATime.run {
            try self.store.deleteThread(threadID: threadID)
            try self.notifyStack(ofThread: threadID)
        }
    }

    /// Resolves or reopens a thread. A reopened thread ports at once from where it was resolved.
    func setResolved(_ resolved: Bool, threadID: Int) async throws {
        try await oneAtATime.run {
            let thread = resolved ? try self.store.resolveThread(threadID: threadID) : try self.store.reopenThread(threadID: threadID)
            if !resolved, let latest = try self.store.latestRevision(stackID: thread.stackID) {
                try await self.portThread(threadID, stackID: thread.stackID, to: latest)
            }
            self.notify(.stack(thread.stackID))
        }
    }

    /// Submits the stack's draft review, following design D, "What Submit review does".
    func submitReview(stackID: Int, verdict: ReviewVerdict, summary: String) async throws {
        try await oneAtATime.run { _ = try await self.submitReviewNow(stackID: stackID, verdict: verdict, summary: summary) }
    }

    func submitReviewNow(stackID: Int, verdict: ReviewVerdict, summary: String) async throws -> ReviewRecord {
        let newest = try await snapshotIfMoved(stackID)
        if let repo = try store.stack(id: stackID).flatMap({ try store.repo(id: $0.repoID) }),
           let repository = try? await repository(for: repo) {
            try await portOpenThreads(stackID: stackID, to: newest, in: repository)
        }
        let draft = try store.draftReview(stackID: stackID)
        let review = try store.submitReview(reviewID: draft.id, verdict: verdict, body: summary, revisionID: newest.id)
        await announceReview(review, stackID: stackID)
        notify(.stack(stackID))
        return review
    }

    /// Opens a repo: the gh-stack stack holding its current branch, else that branch on its own
    /// against the default trunk. It takes a `human_start` revision with pins.
    func openRepository(at folder: URL) async throws -> (stack: StackRecord, repo: RepoRecord, revisionID: Int) {
        try await oneAtATime.run {
            let repository = try await self.repository(at: folder)
            guard let branch = try await repository.currentBranch() else {
                throw EyeballsError(.noStack, "HEAD is detached in that repository, so Eyeballs cannot tell which stack to open.",
                                    hint: "Check out a branch of the stack, then open it again.")
            }
            let found = try await self.findStack(containing: branch, in: repository)
            let repo = try await self.recordRepo(repository, remote: found.discovered.remoteRepository)
            let stack = try self.store.findOrCreateStack(repoID: repo.id, Self.description(of: found.discovered)).stack
            let outcome = try await self.recordRevision(found.discovered, of: stack, repo: repo, in: repository,
                                                        trigger: .humanStart, session: nil, note: nil, dirtyFiles: 0)
            self.notify(.stack(stack.id))
            return (stack, repo, outcome.revision.id)
        }
    }

    /// Closes stacks you are done with: they leave the window, their history stays, and an agent
    /// waiting on one is told it closed.
    func closeStacks(_ stackIDs: [Int]) async throws {
        try await oneAtATime.run {
            for stackID in stackIDs {
                guard let facts = try? self.facts(stackID), facts.stack.state == .active else { continue }
                try self.store.archiveStack(stackID: stackID)
                if let driver = facts.driver {
                    let event = AgentEvents.stackClosed(stack: stackID, label: self.stackLabel(facts.stack), reviewer: await self.reviewerName(for: facts.repo))
                    self.broadcast(event, to: Self.listener(for: driver))
                }
                self.notify(.stack(stackID))
            }
        }
    }

    // MARK: Waking the agent

    private func portThread(_ threadID: Int, stackID: Int, to revision: RevisionRecord) async throws {
        guard let repo = try store.stack(id: stackID).flatMap({ try store.repo(id: $0.repoID) }) else { return }
        let repository = try await repository(for: repo)
        try await portOpenThreads(stackID: stackID, to: revision, in: repository, only: [threadID])
    }

    /// Sends `review.submitted` or `review.approved` to every connection of the driver's Claude process (fix 10).
    private func announceReview(_ review: ReviewRecord, stackID: Int) async {
        guard let facts = try? facts(stackID), let driver = facts.driver else { return }
        let event = AgentEvents.reviewSubmitted(
            review: review.id, verdict: ReviewVerdictWords(wire: (review.verdict ?? .comment).wire), stack: stackID, name: facts.stack.name,
            revision: facts.latestRevision?.number ?? 0, reviewer: await reviewerName(for: facts.repo), threads: threadCount(of: review, in: facts))
        let reached = broadcast(event, to: Self.listener(for: driver))
        Log.server.info("Review \(review.id, privacy: .public) reached \(reached, privacy: .public) connections")
    }

    private func announceComment(on threadID: Int, stackID: Int) async {
        guard let facts = try? facts(stackID), let driver = facts.driver else { return }
        let event = AgentEvents.commentSent(thread: threadID, stack: stackID, name: facts.stack.name,
                                            revision: facts.latestRevision?.number ?? 0, reviewer: await reviewerName(for: facts.repo))
        broadcast(event, to: Self.listener(for: driver))
    }

    private func notifyStack(ofThread threadID: Int) throws {
        if let thread = try store.thread(id: threadID) { notify(.stack(thread.stackID)) }
    }

    #if DEBUG
    // MARK: debug.submitReview

    /// Plays you for `Scripts/fake-agent.sh`: one comment, then a submit, exactly as the window does them.
    func debugSubmitReview(_ arguments: DebugSubmitReviewArguments, client: ClientIdentity) async throws -> (DebugSubmitReviewResult, String) {
        try await oneAtATime.run {
            guard let stack = try await self.knownStack(arguments.stack, client: client, session: nil) else {
                throw EyeballsError(.noStack, "There is no stack here to review.", hint: "Run eyeballs review first, or pass --stack.")
            }
            let facts = try self.facts(stack.id)
            guard let latest = facts.latestRevision else { throw EyeballsError(.noStack, "\(self.stackLabel(stack)) has no revision yet.") }

            let threadID: Int
            let commentID: Int
            if let thread = arguments.thread {
                let comment = try await self.replyNow(arguments.body, to: thread.number, sendNow: arguments.sendNow)
                (threadID, commentID) = (thread.number, comment.id)
            } else {
                let path = arguments.path ?? ""
                let snapshots = facts.revisionSnapshots[latest.id] ?? [:]
                let files = try self.store.files(ofSnapshots: Array(snapshots.values))
                guard let layer = facts.activeLayers.first(where: { layer in
                    snapshots[layer.id].map { (files[$0] ?? []).contains { $0.path == path } } ?? false
                }) else {
                    throw EyeballsError.badInput("No layer of \(self.stackLabel(stack)) changes that file.", hint: "Name a file from the layer's diff.")
                }
                let anchor: ThreadAnchor = arguments.line.map { line in
                    .lines(LineRange(path: path, side: arguments.side == .base ? .base : .head, start: line, end: arguments.endLine ?? line))
                } ?? .file(path: path)
                let created = try await self.addCommentNow(arguments.body, at: anchor, layerID: layer.id, viewing: latest.id, sendNow: arguments.sendNow)
                (threadID, commentID) = (created.thread.id, created.comment.id)
            }

            var reviewID: Int?
            if !arguments.sendNow {
                reviewID = try await self.submitReviewNow(stackID: stack.id, verdict: ReviewVerdict(arguments.verdict), summary: arguments.summary).id
            }
            let result = DebugSubmitReviewResult(stack: StackID(stack.id), review: reviewID, thread: ThreadID(threadID), comment: CommentID(commentID))
            let text = reviewID.map { "Submitted review \($0) on \(self.stackLabel(stack)) with t\(threadID)." }
                ?? "Sent c\(commentID) on t\(threadID) now."
            return (result, text)
        }
    }
    #endif
}

extension Store {
    func layer(id: Int) throws -> LayerRecord? {
        try reader.read { try LayerRecord.fetchOne($0, id: id) }
    }
}

extension Verdict {
    init(_ verdict: ReviewVerdict) {
        switch verdict {
        case .changesRequested: self = .requestChanges
        case .approved: self = .approve
        default: self = .comment
        }
    }
}

extension ReviewVerdict {
    init(_ verdict: Verdict) {
        switch verdict {
        case .comment: self = .comment
        case .requestChanges: self = .changesRequested
        case .approve: self = .approved
        }
    }
}

extension ReplyStatus {
    init?(_ status: AgentReplyStatus) {
        switch status {
        case .addressed: self = .addressed
        case .declined: self = .declined
        case .question: self = .question
        case .unknown: return nil
        }
    }
}

extension FileChange {
    init(_ change: DiffChange) {
        switch change {
        case .added: self = .added
        case .modified: self = .modified
        case .deleted: self = .deleted
        case .renamed: self = .renamed
        case .copied: self = .copied
        case .typeChanged: self = .typeChanged
        }
    }
}

extension LineKind {
    init(_ kind: DiffLineKind) {
        switch kind {
        case .context: self = .context
        case .added: self = .added
        case .deleted: self = .deleted
        }
    }
}
