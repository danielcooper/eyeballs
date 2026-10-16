import Foundation
import Observation

/// What the window's columns share that is not review data: the middle column's tab, the
/// review being finished, the files you marked viewed, and a way to ask the diff pane to scroll.
@MainActor
@Observable
final class ReviewWindowState {
    enum MiddleTab: Hashable {
        case files, threads
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
    /// changes since is no longer viewed. The window keeps these until it quits.
    private(set) var viewedFiles: [Int: [String: FileFingerprint]] = [:]

    @ObservationIgnored weak var pane: DiffPaneController?
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
        viewedFiles[layerID]?[file.path] == FileFingerprint(file)
    }

    func setViewed(_ viewed: Bool, file: FileItem, layerID: Int) {
        if viewed {
            viewedFiles[layerID, default: [:]][file.path] = FileFingerprint(file)
        } else {
            viewedFiles[layerID]?[file.path] = nil
        }
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

/// A cheap stand-in for a file's diff, so a Viewed mark lapses when the diff changes.
struct FileFingerprint: Hashable {
    var additions: Int
    var deletions: Int
    var hunkHeaders: [String]
    var lineCount: Int

    init(_ file: FileItem) {
        additions = file.additions
        deletions = file.deletions
        hunkHeaders = file.hunks.map(\.header)
        lineCount = file.newLines.count + file.oldLines.count
    }
}

extension ThreadItem {
    /// The lines this thread was written on are gone, so it shows its original code instead.
    var isOutdated: Bool { !originalLines.isEmpty }

    var hasSentComments: Bool { comments.contains { !$0.isPending } }
}
