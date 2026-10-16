#if DEBUG
import AppKit

/// A backend that keeps a whole review in memory, so every part of the window works without a
/// store, git or an agent. Launch a Debug build with `-EyeballsDemo YES` to use it.
///
/// After you submit, it plays the agent: two seconds later it marks the review delivered and
/// replies to two threads, one addressed and one with a question.
@MainActor
final class DemoReviewBackend: ReviewBackend {
    private let model: ReviewWindowModel
    private var state: DemoState
    /// How long the pretend agent takes to read a review and reply.
    var agentDelay: Duration = .seconds(2)

    init(model: ReviewWindowModel) {
        self.model = model
        state = DemoState.seeded(now: Date())
        model.agent = Self.listening
        publishRepositories()
        if let layer = state.layers.first(where: { $0.item.position == 1 }) {
            select(LayerSelection(stackID: state.stack.id, layerID: layer.item.id))
        }
    }

    private static let listening = AgentStatus(text: "Claude listening", isListening: true, agentName: "Claude")

    // MARK: ReviewBackend

    func select(_ selection: LayerSelection) {
        guard state.layers.contains(where: { $0.item.id == selection.layerID }) else { return }
        model.selection = selection
        publishLayer()
    }

    func selectLayer(atPosition position: Int) {
        guard let layer = state.layers.first(where: { $0.item.position == position }) else { return }
        select(LayerSelection(stackID: state.stack.id, layerID: layer.item.id))
    }

    func addComment(_ body: String, at anchor: NewThreadAnchor, sendNow: Bool) {
        guard let layerID = model.selection?.layerID else { return }
        let thread = DemoThread(
            id: state.nextThreadID, layerID: layerID, anchor: anchor,
            comments: [state.makeComment(.you(name: DemoState.reviewer), body: body, pending: !sendNow)])
        state.nextThreadID += 1
        state.threads.append(thread)
        publishAll()
        if sendNow { answerSoon([thread.id]) }
    }

    func reply(_ body: String, to threadID: Int, sendNow: Bool) {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else { return }
        state.threads[index].comments.append(state.makeComment(.you(name: DemoState.reviewer), body: body, pending: !sendNow))
        publishAll()
        if sendNow { answerSoon([threadID]) }
    }

    func editComment(_ commentID: Int, body: String) {
        state.updateComment(commentID) { comment in
            comment.body = body
            if !comment.isPending { comment.isEdited = true }
        }
        publishAll()
    }

    func deleteComment(_ commentID: Int) {
        for index in state.threads.indices {
            state.threads[index].comments.removeAll { $0.id == commentID }
        }
        state.threads.removeAll { $0.comments.isEmpty }
        publishAll()
    }

    func setResolved(_ resolved: Bool, threadID: Int) {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else { return }
        state.threads[index].isResolved = resolved
        publishAll()
    }

    func draft(for key: DraftKey) -> String {
        state.drafts[key] ?? ""
    }

    func saveDraft(_ text: String, for key: DraftKey) {
        state.drafts[key] = text.isEmpty ? nil : text
        if key == .reviewSummary { model.review.summary = text }
    }

    func submitReview(verdict: Verdict, summary: String) {
        var sentThreads: [Int] = []
        for index in state.threads.indices {
            var sent = false
            for commentIndex in state.threads[index].comments.indices where state.threads[index].comments[commentIndex].isPending {
                state.threads[index].comments[commentIndex].isPending = false
                state.threads[index].comments[commentIndex].date = Date()
                sent = true
            }
            if sent { sentThreads.append(state.threads[index].id) }
        }
        let number = state.nextReviewNumber
        state.nextReviewNumber += 1
        state.lastSubmitted = SubmittedReview(number: number, verdict: verdict, date: Date(), deliveredAt: nil)
        state.drafts[.reviewSummary] = nil
        model.agent = AgentStatus(text: "Claude reading review \(number)", isListening: true, agentName: "Claude")
        publishAll()
        deliverSoon(review: number, verdict: verdict, threads: sentThreads)
    }

    func copyAgentPrompt() {
        let review = state.lastSubmitted.map { "review \($0.number)" } ?? "the open review"
        let prompt = "Eyeballs has \(review) for \(state.stack.name) (s\(state.stack.id)). Run `eyeballs inbox`, then reply to every thread with `eyeballs reply --file -`."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    func openRepository(at url: URL) {
        let name = url.lastPathComponent
        guard name != state.repository.name, !state.extraRepositories.contains(where: { $0.path == url.path }) else { return }
        state.extraRepositories.append(RepositoryItem(id: 100 + state.extraRepositories.count, name: name, path: url.path, stacks: []))
        publishRepositories()
    }

    func acceptBanner() {
        model.banner = nil
        state.stack.revision = (state.stack.revision ?? 0) + 1
        publishRepositories()
    }

    // MARK: The pretend agent

    private func deliverSoon(review number: Int, verdict: Verdict, threads: [Int]) {
        let delay = agentDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.state.lastSubmitted?.deliveredAt = Date()
            self.publishAll()
            guard verdict != .approve else {
                self.model.agent = Self.listening
                return
            }
            let waiting = self.state.threads.filter { thread in
                !thread.isResolved && thread.comments.last.map { !$0.author.isAgent && !$0.isPending } == true
            }.map(\.id)
            let targets = Array((threads + waiting.filter { !threads.contains($0) }).prefix(2))
            self.answer(targets)
            self.model.agent = Self.listening
            if !targets.isEmpty {
                self.model.banner = Banner(message: "Claude pushed r\((self.state.stack.revision ?? 0) + 1) with fixes for review \(number).",
                                           actionTitle: "Show r\((self.state.stack.revision ?? 0) + 1)")
            }
        }
    }

    private func answerSoon(_ threadIDs: [Int]) {
        let delay = agentDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.answer(threadIDs)
        }
    }

    private func answer(_ threadIDs: [Int]) {
        for (position, id) in threadIDs.enumerated() {
            guard let index = state.threads.firstIndex(where: { $0.id == id }) else { continue }
            let isQuestion = position == 1 || threadIDs.count == 1 && state.threads[index].comments.count > 2
            let body = isQuestion
                ? "Before I change this: should it apply to the other callers in this layer too, or only here?"
                : "Done. I changed it as you suggested and added a test that covers it. It's in the next revision."
            state.threads[index].comments.append(state.makeComment(.agent(name: "Claude"), body: body, pending: false, status: isQuestion ? .question : .addressed))
        }
        publishAll()
    }

    // MARK: Publishing to the model

    private func publishAll() {
        publishRepositories()
        publishLayer()
    }

    private func publishRepositories() {
        var stack = state.stack
        stack.layers = state.layers.map { layer in
            var item = layer.item
            item.openThreadCount = state.threads.filter { $0.layerID == item.id && !$0.isResolved }.count
            return item
        }
        stack.openThreadCount = state.threads.filter { !$0.isResolved }.count
        stack.needsYouCount = state.threads.filter { $0.derivedState.needsYou }.count
        var repository = state.repository
        repository.stacks = [stack]
        model.repositories = [repository] + state.extraRepositories
        model.review = PendingReview(
            pendingCommentCount: state.threads.reduce(0) { $0 + $1.comments.filter(\.isPending).count },
            summary: state.drafts[.reviewSummary] ?? "",
            lastSubmitted: state.lastSubmitted)
    }

    private func publishLayer() {
        guard let layerID = model.selection?.layerID, let layer = state.layers.first(where: { $0.item.id == layerID }) else {
            model.layer = nil
            return
        }
        model.layer = LayerContent(
            layerID: layerID, commits: layer.commits, files: layer.files,
            threads: state.threads.filter { $0.layerID == layerID }.map(\.item))
    }
}

/// Everything the demo backend knows.
@MainActor
struct DemoState {
    static let reviewer = "Alex Kim"

    var repository: RepositoryItem
    var extraRepositories: [RepositoryItem] = []
    var stack: StackItem
    var layers: [DemoLayer]
    var threads: [DemoThread]
    var drafts: [DraftKey: String] = [:]
    var lastSubmitted: SubmittedReview?
    var nextReviewNumber = 7
    var nextThreadID = 48
    var nextCommentID = 300

    mutating func makeComment(_ author: Author, body: String, pending: Bool, status: ReplyStatus? = nil, date: Date = Date()) -> CommentItem {
        defer { nextCommentID += 1 }
        return CommentItem(id: nextCommentID, author: author, replyStatus: status, body: body, date: date, isPending: pending, isEdited: false)
    }

    mutating func updateComment(_ id: Int, _ change: (inout CommentItem) -> Void) {
        for threadIndex in threads.indices {
            if let commentIndex = threads[threadIndex].comments.firstIndex(where: { $0.id == id }) {
                change(&threads[threadIndex].comments[commentIndex])
            }
        }
    }
}

struct DemoLayer {
    var item: LayerItem
    var commits: [CommitItem]
    var files: [FileItem]
}

struct DemoThread {
    var id: Int
    var layerID: Int
    var anchor: ThreadAnchor
    var comments: [CommentItem]
    var isResolved = false
    var anchorNote: String?
    var originalLines: [String] = []

    var item: ThreadItem {
        ThreadItem(id: id, anchor: anchor, comments: comments, isResolved: isResolved, state: derivedState,
                   anchorNote: anchorNote, originalLines: originalLines)
    }

    /// The design's rule table: the first rule that matches wins.
    var derivedState: ThreadState {
        if isResolved { return .resolved }
        guard let last = comments.last else { return .draft }
        if comments.allSatisfy(\.isPending) || last.isPending { return .draft }
        switch last.replyStatus {
        case .question: return .agentAsks
        case .addressed: return .checkTheFix
        case .declined: return .agentDeclined
        case nil: return .waitingOnAgent
        }
    }
}
#endif
