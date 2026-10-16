import Foundation

/// Where a thread stands, worked out from its status and its comments.
///
/// The window and the agent's packets both use this, so they never disagree. It follows the
/// "Derived thread state" table in design section B: the first rule that matches wins.
/// Deleted comments are ignored, and an unsent comment of yours never counts as the last word.
public struct ThreadProgress: Hashable, Sendable {
    /// What you see on the thread's status chip.
    public var state: DerivedThreadState
    /// How the agent sees the thread, when it waits on the agent. Nil otherwise.
    public var agentKind: AgentThreadKind?

    public var waitsOnAgent: Bool { agentKind != nil }

    public init(thread: ThreadRecord, comments: [CommentRecord]) {
        let live = comments.filter { $0.deletedAt == nil }
        let sent = live.filter { $0.sentAt != nil }.sorted(by: Self.sentOrder)
        state = Self.state(status: thread.status, sent: sent)
        agentKind = Self.agentKind(thread: thread, sent: sent)
    }

    private static func state(status: ThreadStatus, sent: [CommentRecord]) -> DerivedThreadState {
        if status == .resolved { return .resolved }
        guard let last = sent.last else { return .draft }
        switch (last.author, last.replyStatus) {
        case (.human, _): return .waitingOnAgent
        case (.agent, .addressed?): return .checkTheFix
        case (.agent, .declined?): return .agentDeclined
        // A question, or a status from a newer version that this one cannot name: either way it needs you.
        case (.agent, _): return .agentAsks
        }
    }

    private static func agentKind(thread: ThreadRecord, sent: [CommentRecord]) -> AgentThreadKind? {
        guard thread.status == .open, thread.deletedAt == nil, sent.last?.author == .human else { return nil }
        let lastAgentReply = sent.last { $0.author == .agent }
        if let resolvedAt = thread.resolvedAt, resolvedAt > (lastAgentReply?.createdAt ?? .distantPast) {
            return .reopened
        }
        guard let lastAgentReply else { return .new }
        return lastAgentReply.replyStatus == .question ? .answer : .followUp
    }

    /// Comments in the order they reached the other side: a comment sent with a review comes
    /// after an agent reply written while it sat in the draft.
    static func sentOrder(_ a: CommentRecord, _ b: CommentRecord) -> Bool {
        (a.sentAt ?? .distantFuture, a.id) < (b.sentAt ?? .distantFuture, b.id)
    }
}

/// The derived thread states of design section B, in rule order.
public enum DerivedThreadState: Hashable, Sendable, CaseIterable {
    /// `status = resolved`.
    case resolved
    /// Every comment is still in your draft review.
    case draft
    /// The last comment is an agent `question`.
    case agentAsks
    /// The last comment is an agent `addressed` reply.
    case checkTheFix
    /// The last comment is an agent `declined` reply.
    case agentDeclined
    /// The last comment is yours, and it has been sent.
    case waitingOnAgent

    /// True for the states that count toward the Dock badge.
    public var needsYou: Bool {
        self == .agentAsks || self == .checkTheFix || self == .agentDeclined
    }
}

/// How a thread that waits on the agent is labelled in its packet.
public enum AgentThreadKind: String, Hashable, Sendable, Codable {
    /// Your first comment. The agent has not replied yet.
    case new
    /// You replied after the agent's reply.
    case followUp = "follow-up"
    /// You answered the agent's question.
    case answer
    /// You reopened a resolved thread.
    case reopened
}
