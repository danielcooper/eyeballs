import Foundation
import Observation

/// What the window's columns share that is not review data: the middle column's tab, the
/// review being finished, the files you marked viewed, and a way to ask the diff pane to scroll.
@MainActor
@Observable
final class ReviewWindowState {
    enum MiddleTab: Hashable {
        case files, commits, threads
    }

    var middleTab = MiddleTab.files
    var threadScope = ThreadScope.thisLayer
    var threadFilter = ThreadFilter.all
    /// True while the Finish review popover is open.
    var isFinishingReview = false
    var verdict = Verdict.comment
    /// The review summary as you type it. It is saved as the `.reviewSummary` draft.
    var summaryText = ""
    /// The file whose header is pinned at the top of the diff pane.
    var currentFilePath: String?
    var focusedThreadID: Int?
    /// Files you ticked Viewed, by layer ID, with the diff they had then. A file whose diff
    /// changes since is no longer viewed. The marks are saved per stack in `viewedMarksStore`.
    private(set) var viewedFiles: ViewedMarks = [:]

    @ObservationIgnored weak var pane: DiffPaneController?
    /// Nil keeps Viewed marks in memory only, as screenshot and self-test runs do.
    @ObservationIgnored var viewedMarksStore: ViewedMarksStore?
    @ObservationIgnored private var stackOfLayer: [Int: Int] = [:]
    @ObservationIgnored private var loadedViewedMarksForStacks: Set<Int> = []
    @ObservationIgnored private var fingerprints: [FingerprintKey: (file: FileItem, fingerprint: FileFingerprint)] = [:]
    /// A thread to show once its layer has loaded, after a jump from another layer.
    @ObservationIgnored var threadToRevealAfterLoad: Int?
    /// A layer comment to open, already written, once its layer has loaded.
    @ObservationIgnored var layerCommentToOpenAfterLoad: PendingLayerComment?
    @ObservationIgnored private var summarySave: Task<Void, Never>?
    @ObservationIgnored private var loadedSummaryForStack: Int?

    func revealFile(_ path: String) { pane?.revealFile(path) }
    func revealThread(_ id: Int) { pane?.revealThread(id) }
    func revealOverview() { pane?.revealOverview() }

    /// Shows a thread anywhere in the stack, switching layer first when it is on another one.
    func showThread(_ id: Int, in model: ReviewWindowModel) {
        if model.layer?.threads.contains(where: { $0.id == id }) == true {
            revealThread(id)
            return
        }
        guard let stack = model.selectedStack,
              let layerID = model.threadsByLayer.first(where: { $0.value.contains { $0.id == id } })?.key else { return }
        threadToRevealAfterLoad = id
        model.select(LayerSelection(stackID: stack.id, layerID: layerID))
    }

    /// Clears the error and reads the selected layer again, which is how every read is retried.
    func retryAfterError(_ model: ReviewWindowModel) {
        model.errorMessage = nil
        if let selection = model.selection { model.select(selection) }
    }

    /// Starts a layer comment that asks the agent to restack the layer onto its parent. You
    /// still choose whether to add it to the review or send it now.
    func askToRestack(_ layer: LayerItem, in model: ReviewWindowModel) {
        guard let stack = model.repositories.lazy.flatMap(\.stacks).first(where: { $0.layers.contains { $0.id == layer.id } }) else { return }
        let parent = stack.layers.first { $0.position == layer.position - 1 }?.branch ?? stack.trunk
        layerCommentToOpenAfterLoad = PendingLayerComment(
            layerID: layer.id,
            text: "This layer no longer sits on top of `\(parent)`. Please restack the stack, then run `eyeballs review` again.")
        if model.selection?.layerID == layer.id {
            pane?.openLayerCommentWaitingForLoad()
        } else {
            model.select(LayerSelection(stackID: stack.id, layerID: layer.id))
        }
    }

    /// Moves to the layer above (`offset` 1) or below (`offset` -1) the selected one.
    func selectAdjacentLayer(_ offset: Int, in model: ReviewWindowModel) {
        guard let target = adjacentLayer(offset, in: model) else { return }
        model.selectLayer(atPosition: target.position)
    }

    func adjacentLayer(_ offset: Int, in model: ReviewWindowModel) -> LayerItem? {
        guard let layer = model.selectedLayer, let stack = model.selectedStack else { return nil }
        return stack.layers.first { $0.position == layer.position + offset }
    }

    // MARK: Viewed files

    func isViewed(_ file: FileItem, layerID: Int) -> Bool {
        guard let mark = viewedFiles[layerID]?[file.path] else { return false }
        return mark == fingerprint(of: file, layerID: layerID)
    }

    /// True when you ticked the file Viewed, whether or not its diff has changed since.
    func hasViewedMark(_ path: String, layerID: Int) -> Bool {
        viewedFiles[layerID]?[path] != nil
    }

    func setViewed(_ viewed: Bool, file: FileItem, layerID: Int, stackID: Int?) {
        if viewed {
            viewedFiles[layerID, default: [:]][file.path] = fingerprint(of: file, layerID: layerID)
        } else {
            viewedFiles[layerID]?[file.path] = nil
        }
        guard let stackID else { return }
        stackOfLayer[layerID] = stackID
        viewedMarksStore?.save(viewedFiles.filter { stackOfLayer[$0.key] == stackID }, forStack: stackID)
    }

    /// Reads a stack's saved Viewed marks the first time the window shows that stack.
    func loadViewedMarksIfNeeded(from model: ReviewWindowModel) {
        guard let stack = model.selectedStack, !loadedViewedMarksForStacks.contains(stack.id) else { return }
        loadedViewedMarksForStacks.insert(stack.id)
        guard let saved = viewedMarksStore?.marks(forStack: stack.id) else { return }
        let layers = Set(stack.layers.map(\.id))
        for (layerID, marks) in saved where layers.contains(layerID) {
            stackOfLayer[layerID] = stack.id
            viewedFiles[layerID, default: [:]].merge(marks) { current, _ in current }
        }
    }

    /// Hashing a big diff is not free, so each file's fingerprint is kept until the file changes.
    private func fingerprint(of file: FileItem, layerID: Int) -> FileFingerprint {
        let key = FingerprintKey(layerID: layerID, path: file.path)
        if let cached = fingerprints[key], cached.file == file { return cached.fingerprint }
        let fingerprint = FileFingerprint(file)
        fingerprints[key] = (file, fingerprint)
        return fingerprint
    }

    private struct FingerprintKey: Hashable {
        var layerID: Int
        var path: String
    }

    func viewedCount(in layer: LayerContent) -> Int {
        layer.files.filter { isViewed($0, layerID: layer.layerID) }.count
    }

    // MARK: Finishing the review

    /// Loads the saved summary draft once per stack, so switching layers never loses typing.
    func loadSummaryIfNeeded(from model: ReviewWindowModel) {
        let stackID = model.selection?.stackID
        guard stackID != loadedSummaryForStack else { return }
        loadedSummaryForStack = stackID
        let draft = model.draft(for: .reviewSummary)
        summaryText = draft.isEmpty ? model.review.summary : draft
    }

    func summaryDidChange(_ text: String, model: ReviewWindowModel) {
        summarySave?.cancel()
        summarySave = Task { [weak model] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model?.saveDraft(text, for: .reviewSummary)
        }
    }

    /// Opens the Finish review popover. Submitting is always a second, deliberate step.
    func finishReview(_ model: ReviewWindowModel) {
        guard model.selectedStack != nil else { return }
        isFinishingReview = true
    }

    func canSubmit(_ model: ReviewWindowModel) -> Bool {
        guard model.selectedStack != nil else { return false }
        let hasSummary = !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return model.review.pendingCommentCount > 0 || hasSummary || verdict == .approve
    }

    func submit(_ model: ReviewWindowModel) {
        guard canSubmit(model) else { return }
        summarySave?.cancel()
        model.submitReview(verdict: verdict, summary: summaryText.trimmingCharacters(in: .whitespacesAndNewlines))
        summaryText = ""
        model.saveDraft("", for: .reviewSummary)
        verdict = .comment
        isFinishingReview = false
    }
}

struct PendingLayerComment {
    var layerID: Int
    var text: String
}

/// Which threads the Threads tab lists.
enum ThreadScope: Hashable, CaseIterable {
    case thisLayer, wholeStack

    var label: String {
        switch self {
        case .thisLayer: "This layer"
        case .wholeStack: "Whole stack"
        }
    }
}

/// Narrows the Threads tab to one kind of thread.
enum ThreadFilter: Hashable, CaseIterable {
    case all, needsYou, drafts, waitingOnAgent, outdated, resolved

    var label: String {
        switch self {
        case .all: "All threads"
        case .needsYou: "Needs you"
        case .drafts: "Drafts"
        case .waitingOnAgent: "Waiting on agent"
        case .outdated: "Outdated"
        case .resolved: "Resolved"
        }
    }

    /// Says what a filtered list holds, such as "Showing outdated threads".
    var showingText: String {
        switch self {
        case .all: "Showing all threads"
        case .needsYou: "Showing threads that need you"
        case .drafts: "Showing drafts"
        case .waitingOnAgent: "Showing threads waiting on the agent"
        case .outdated: "Showing outdated threads"
        case .resolved: "Showing resolved threads"
        }
    }

    func includes(_ thread: ThreadItem) -> Bool {
        switch self {
        case .all: true
        case .needsYou: thread.state.needsYou
        case .drafts: thread.state == .draft
        case .waitingOnAgent: thread.state == .waitingOnAgent
        case .outdated: thread.isOutdated && !thread.isResolved
        case .resolved: thread.isResolved
        }
    }
}

extension ThreadItem {
    /// The lines this thread was written on are gone, so it shows its original code instead.
    var isOutdated: Bool { !originalLines.isEmpty }

    var hasSentComments: Bool { comments.contains { !$0.isPending } }
}
