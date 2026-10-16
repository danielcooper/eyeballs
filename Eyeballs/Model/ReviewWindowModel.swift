import Foundation
import Observation

/// Everything the review window shows, and the one door it uses to change anything.
///
/// Views read these properties and call the methods at the bottom. They never reach the store,
/// git or the socket themselves. A `ReviewBackend` does the work and writes the results back here.
@MainActor
@Observable
final class ReviewWindowModel {
    var repositories: [RepositoryItem] = []
    var selection: LayerSelection?
    var layer: LayerContent?
    var review = PendingReview()
    var agent = AgentStatus.notListening
    var banner: Banner?
    var isLoadingLayer = false
    var errorMessage: String?

    @ObservationIgnored weak var backend: ReviewBackend?

    var selectedStack: StackItem? {
        guard let selection else { return nil }
        return repositories.lazy.flatMap(\.stacks).first { $0.id == selection.stackID }
    }

    var selectedLayer: LayerItem? {
        guard let selection else { return nil }
        return selectedStack?.layers.first { $0.id == selection.layerID }
    }

    func select(_ selection: LayerSelection) { backend?.select(selection) }
    func selectLayer(atPosition position: Int) { backend?.selectLayer(atPosition: position) }
    func addComment(_ body: String, at anchor: NewThreadAnchor, sendNow: Bool) { backend?.addComment(body, at: anchor, sendNow: sendNow) }
    func reply(_ body: String, to threadID: Int, sendNow: Bool) { backend?.reply(body, to: threadID, sendNow: sendNow) }
    func editComment(_ commentID: Int, body: String) { backend?.editComment(commentID, body: body) }
    func deleteComment(_ commentID: Int) { backend?.deleteComment(commentID) }
    func setResolved(_ resolved: Bool, threadID: Int) { backend?.setResolved(resolved, threadID: threadID) }
    func draft(for key: DraftKey) -> String { backend?.draft(for: key) ?? "" }
    func saveDraft(_ text: String, for key: DraftKey) { backend?.saveDraft(text, for: key) }
    func submitReview(verdict: Verdict, summary: String) { backend?.submitReview(verdict: verdict, summary: summary) }
    func copyAgentPrompt() { backend?.copyAgentPrompt() }
    func openRepository(at url: URL) { backend?.openRepository(at: url) }
    func acceptBanner() { backend?.acceptBanner() }
}

/// Does the work behind the window. The real one uses the store, git and the agent socket;
/// the demo one keeps everything in memory.
@MainActor
protocol ReviewBackend: AnyObject {
    func select(_ selection: LayerSelection)
    func selectLayer(atPosition position: Int)
    func addComment(_ body: String, at anchor: NewThreadAnchor, sendNow: Bool)
    func reply(_ body: String, to threadID: Int, sendNow: Bool)
    func editComment(_ commentID: Int, body: String)
    func deleteComment(_ commentID: Int)
    func setResolved(_ resolved: Bool, threadID: Int)
    func draft(for key: DraftKey) -> String
    func saveDraft(_ text: String, for key: DraftKey)
    func submitReview(verdict: Verdict, summary: String)
    func copyAgentPrompt()
    func openRepository(at url: URL)
    func acceptBanner()
}

// MARK: Sidebar

struct RepositoryItem: Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var path: String
    var stacks: [StackItem]
}

struct StackItem: Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var trunk: String
    /// The newest revision number, shown as `r4`. Nil before the agent's first `eyeballs review`.
    var revision: Int?
    /// Bottom layer first. Layer 1 is the bottom; the sidebar shows them top first.
    var layers: [LayerItem]
    var openThreadCount: Int
    var needsYouCount: Int
}

struct LayerItem: Identifiable, Hashable, Sendable {
    let id: Int
    var position: Int
    var branch: String
    var prNumber: Int?
    var fileCount: Int
    var additions: Int
    var deletions: Int
    var openThreadCount: Int
    var status: LayerStatus
}

enum LayerStatus: Hashable, Sendable {
    case ready
    case needsRestack
    case merged
    case empty
}

struct LayerSelection: Hashable, Sendable {
    var stackID: Int
    var layerID: Int
}

// MARK: Diff

struct LayerContent: Sendable {
    var layerID: Int
    /// The commits in this layer, newest first, for the layer overview.
    var commits: [CommitItem]
    var files: [FileItem]
    /// Threads on a line range or a file, plus layer-level threads (anchor `.layer`).
    var threads: [ThreadItem]
}

struct CommitItem: Identifiable, Hashable, Sendable {
    var id: String { sha }
    var sha: String
    var subject: String
    var author: String
    var date: Date
}

struct FileItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    /// Set for renames and copies.
    var oldPath: String?
    var change: FileChange
    var additions: Int
    var deletions: Int
    var isBinary: Bool
    var hunks: [HunkItem]
    /// The full new-side text of the file, line by line, so the pane can expand context.
    /// Empty when the file was deleted or is binary.
    var newLines: [String]
    var oldLines: [String]
}

enum FileChange: Hashable, Sendable {
    case added, modified, deleted, renamed, copied, typeChanged
}

struct HunkItem: Hashable, Sendable {
    /// For example `@@ -40,6 +40,9 @@ func get(_ path: String)`.
    var header: String
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var lines: [LineItem]
}

struct LineItem: Hashable, Sendable {
    var kind: LineKind
    var oldNumber: Int?
    var newNumber: Int?
    var text: String
}

enum LineKind: Hashable, Sendable {
    case context, added, deleted
}

/// The side of the diff a comment is on, as GitHub's LEFT and RIGHT.
enum Side: Hashable, Sendable {
    case base, head
}

// MARK: Threads

struct LineRange: Hashable, Sendable {
    var path: String
    var side: Side
    /// 1-based and inclusive, in that side's file.
    var start: Int
    var end: Int
}

enum ThreadAnchor: Hashable, Sendable {
    case lines(LineRange)
    case file(path: String)
    case layer
}

/// Where a brand-new thread goes.
typealias NewThreadAnchor = ThreadAnchor

struct ThreadItem: Identifiable, Hashable, Sendable {
    let id: Int
    var anchor: ThreadAnchor
    var comments: [CommentItem]
    var isResolved: Bool
    var state: ThreadState
    /// Said in words when the thread moved since it was written, for example
    /// "Moved from line 98 (r3)" or "Outdated: the lines this thread was on are gone".
    var anchorNote: String?
    /// The original lines, shown when the thread is outdated.
    var originalLines: [String]
}

enum ThreadState: Hashable, Sendable {
    case resolved, draft, agentAsks, checkTheFix, agentDeclined, waitingOnAgent

    /// The words the UI shows. Colour never carries the meaning on its own.
    var label: String {
        switch self {
        case .resolved: "Resolved"
        case .draft: "Draft"
        case .agentAsks: "Agent asks you"
        case .checkTheFix: "Check the fix"
        case .agentDeclined: "Agent declined"
        case .waitingOnAgent: "Waiting on agent"
        }
    }

    var needsYou: Bool {
        self == .agentAsks || self == .checkTheFix || self == .agentDeclined
    }
}

struct CommentItem: Identifiable, Hashable, Sendable {
    let id: Int
    var author: Author
    /// Set on agent replies only.
    var replyStatus: ReplyStatus?
    var body: String
    var date: Date
    /// True while the comment sits in your unsent review.
    var isPending: Bool
    var isEdited: Bool
}

enum Author: Hashable, Sendable {
    case you(name: String)
    case agent(name: String)
}

enum ReplyStatus: Hashable, Sendable {
    case addressed, declined, question

    var label: String {
        switch self {
        case .addressed: "Addressed"
        case .declined: "Declined"
        case .question: "Question"
        }
    }
}

/// Identifies a composer's draft, so a draft survives scrolling, relaunch and switching layers.
enum DraftKey: Hashable, Sendable {
    case newThread(ThreadAnchor)
    case reply(threadID: Int)
    case reviewSummary
}

// MARK: Review bar and status

struct PendingReview: Hashable, Sendable {
    var pendingCommentCount = 0
    var summary = ""
    var lastSubmitted: SubmittedReview?
}

struct SubmittedReview: Hashable, Sendable {
    var number: Int
    var verdict: Verdict
    var date: Date
    /// Nil until the agent reads it with `eyeballs inbox`.
    var deliveredAt: Date?
}

enum Verdict: Hashable, Sendable, CaseIterable {
    case comment, requestChanges, approve

    var label: String {
        switch self {
        case .comment: "Comment"
        case .requestChanges: "Request changes"
        case .approve: "Approve"
        }
    }
}

struct AgentStatus: Hashable, Sendable {
    var text: String
    var isListening: Bool
    /// The agent's name, such as "Claude", for lines like "waiting for Claude". Nil says "the agent".
    var agentName: String? = nil

    static let notListening = AgentStatus(text: "No agent is listening", isListening: false)
}

struct Banner: Hashable, Sendable {
    var message: String
    var actionTitle: String
}
