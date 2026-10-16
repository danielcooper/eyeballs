import Foundation
import Observation

/// What the window's columns share that is not review data: the middle column's tab, the
/// verdict being chosen, and a way to ask the diff pane to scroll.
@MainActor
@Observable
final class ReviewWindowState {
    enum MiddleTab: Hashable {
        case files, threads
    }

    var middleTab = MiddleTab.files
    var verdict = Verdict.comment
    /// The review summary as you type it. It is saved as the `.reviewSummary` draft.
    var summaryText = ""
    /// The file whose header is pinned at the top of the diff pane.
    var currentFilePath: String?
    var focusedThreadID: Int?

    @ObservationIgnored weak var pane: DiffPaneController?
    @ObservationIgnored private var summarySave: Task<Void, Never>?
    @ObservationIgnored private var loadedSummaryForStack: Int?

    func revealFile(_ path: String) { pane?.revealFile(path) }
    func revealThread(_ id: Int) { pane?.revealThread(id) }
    func revealOverview() { pane?.revealOverview() }

    /// Moves to the layer above (`offset` 1) or below (`offset` -1) the selected one.
    func selectAdjacentLayer(_ offset: Int, in model: ReviewWindowModel) {
        guard let layer = model.selectedLayer, let stack = model.selectedStack else { return }
        let target = layer.position + offset
        guard stack.layers.contains(where: { $0.position == target }) else { return }
        model.selectLayer(atPosition: target)
    }

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
    }
}
