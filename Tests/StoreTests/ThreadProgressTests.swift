@testable import EyeballsStore
import Foundation
import Testing

/// The "Derived thread state" table of design section B, row by row, and the agent-side kinds.
struct ThreadProgressTests {
    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let status: ThreadStatus
        let comments: [CommentRecord]
        let state: DerivedThreadState
        let kind: AgentThreadKind?
        var testDescription: String { name }
    }

    static let tableRows: [Row] = [
        Row(name: "1 Resolved", status: .resolved, comments: [human(1, sentAt: 1)], state: .resolved, kind: nil),
        Row(name: "2 Draft", status: .open, comments: [human(1, sentAt: nil), human(2, sentAt: nil)], state: .draft, kind: nil),
        Row(name: "3 Agent asks you", status: .open, comments: [human(1, sentAt: 1), agent(2, .question, at: 2)], state: .agentAsks, kind: nil),
        Row(name: "4 Check the fix", status: .open, comments: [human(1, sentAt: 1), agent(2, .addressed, at: 2)], state: .checkTheFix, kind: nil),
        Row(name: "5 Agent declined", status: .open, comments: [human(1, sentAt: 1), agent(2, .declined, at: 2)], state: .agentDeclined, kind: nil),
        Row(name: "6 Waiting on agent", status: .open, comments: [human(1, sentAt: 1)], state: .waitingOnAgent, kind: .new),
    ]

    @Test(arguments: tableRows)
    func eachRowOfTheDesignTable(_ row: Row) {
        let progress = ThreadProgress(thread: Self.thread(status: row.status), comments: row.comments)
        #expect(progress.state == row.state)
        #expect(progress.agentKind == row.kind)
    }

    @Test func onlyTheAgentsRepliesCountTowardTheDockBadge() {
        let badge = DerivedThreadState.allCases.filter(\.needsYou)
        #expect(badge == [.agentAsks, .checkTheFix, .agentDeclined])
    }

    @Test func resolvedWinsOverEveryLaterRule() {
        let progress = ThreadProgress(thread: Self.thread(status: .resolved), comments: [Self.human(1, sentAt: 1), Self.agent(2, .question, at: 2)])
        #expect(progress.state == .resolved)
    }

    @Test func aFollowUpComesAfterAnAddressedOrDeclinedReply() {
        for status in [AgentReplyStatus.addressed, .declined] {
            let comments = [Self.human(1, sentAt: 1), Self.agent(2, status, at: 2), Self.human(3, sentAt: 3)]
            let progress = ThreadProgress(thread: Self.thread(), comments: comments)
            #expect(progress.state == .waitingOnAgent)
            #expect(progress.agentKind == .followUp)
        }
    }

    @Test func anAnswerComesAfterAQuestion() {
        let comments = [Self.human(1, sentAt: 1), Self.agent(2, .question, at: 2), Self.human(3, sentAt: 3)]
        #expect(ThreadProgress(thread: Self.thread(), comments: comments).agentKind == .answer)
    }

    @Test func aReopenedThreadWasResolvedAfterTheAgentsLastReply() {
        let comments = [Self.human(1, sentAt: 1), Self.agent(2, .addressed, at: 2), Self.human(3, sentAt: 4)]
        let reopened = ThreadProgress(thread: Self.thread(resolvedAt: Self.time(3)), comments: comments)
        #expect(reopened.agentKind == .reopened)

        let answeredSinceReopening = [Self.human(1, sentAt: 1), Self.agent(2, .addressed, at: 4), Self.human(3, sentAt: 5)]
        #expect(ThreadProgress(thread: Self.thread(resolvedAt: Self.time(3)), comments: answeredSinceReopening).agentKind == .followUp)
    }

    @Test func yourUnsentReplyIsNotTheLastWord() {
        let comments = [Self.human(1, sentAt: 1), Self.agent(2, .question, at: 2), Self.human(3, sentAt: nil)]
        let progress = ThreadProgress(thread: Self.thread(), comments: comments)
        #expect(progress.state == .agentAsks)
        #expect(progress.agentKind == nil)
    }

    @Test func deletedCommentsAreIgnored() {
        var retracted = Self.human(3, sentAt: 3)
        retracted.deletedAt = Self.time(4)
        let comments = [Self.human(1, sentAt: 1), Self.agent(2, .addressed, at: 2), retracted]
        #expect(ThreadProgress(thread: Self.thread(), comments: comments).state == .checkTheFix)
    }

    @Test func aDeletedThreadNeverWaits() {
        var thread = Self.thread()
        thread.deletedAt = Self.time(2)
        #expect(ThreadProgress(thread: thread, comments: [Self.human(1, sentAt: 1)]).agentKind == nil)
    }

    @Test func anAgentStatusFromANewerVersionStillNeedsYou() {
        let comments = [Self.human(1, sentAt: 1), Self.agent(2, .unknown("blocked"), at: 2)]
        #expect(ThreadProgress(thread: Self.thread(), comments: comments).state == .agentAsks)
    }

    @Test func aThreadStatusFromANewerVersionNeverWaits() {
        let progress = ThreadProgress(thread: Self.thread(status: .unknown("snoozed")), comments: [Self.human(1, sentAt: 1)])
        #expect(progress.agentKind == nil)
    }

    // MARK: Records

    static func time(_ second: Int) -> Date {
        Date(timeIntervalSince1970: 1_792_152_000 + TimeInterval(second))
    }

    static func thread(status: ThreadStatus = .open, resolvedAt: Date? = nil) -> ThreadRecord {
        ThreadRecord(id: 41, stackID: 3, layerID: 1, subject: .line, side: .head, openedBy: .human, status: status,
                     resolvedAt: resolvedAt, resolvedRevisionID: nil, deletedAt: nil, createdAt: time(0))
    }

    static func human(_ id: Int, sentAt: Int?) -> CommentRecord {
        comment(id, author: .human, replyStatus: nil, created: id, sentAt: sentAt)
    }

    static func agent(_ id: Int, _ status: AgentReplyStatus, at second: Int) -> CommentRecord {
        comment(id, author: .agent, replyStatus: status, created: second, sentAt: second)
    }

    private static func comment(_ id: Int, author: Participant, replyStatus: AgentReplyStatus?, created: Int, sentAt: Int?) -> CommentRecord {
        CommentRecord(id: id, threadID: 41, author: author, agentSession: nil, reviewID: nil, replyStatus: replyStatus, body: "c\(id)",
                      atRanges: nil, revisionID: 1, fixedIn: nil, sentAt: sentAt.map(time), deliveredAt: nil,
                      createdAt: time(created), updatedAt: time(created), deletedAt: nil)
    }
}
