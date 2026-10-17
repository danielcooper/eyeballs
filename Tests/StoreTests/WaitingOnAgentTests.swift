@testable import EyeballsStore
import Foundation
import Testing

struct WaitingOnAgentTests {
    @Test func onlyOpenLiveThreadsWhoseLastSentCommentIsYoursWait() throws {
        let clock = TestClock()
        try withStore(clock: clock) { store, fixture in
            func tick() { clock.advance(seconds: 1) }

            let new = try fixture.openThread(store, layer: 1, body: "new").thread
            tick()
            try fixture.openThread(store, body: "still a draft", delivery: .addToReview)

            let replied = try fixture.openThread(store, body: "replied").thread
            _ = try store.addAgentReply(threadID: replied.id, status: .addressed, body: "Done.", sessionID: nil)

            let followUp = try fixture.openThread(store, body: "follow-up").thread
            _ = try store.addAgentReply(threadID: followUp.id, status: .declined, body: "Kept it.", sessionID: nil)
            tick()
            let followUpComment = try store.addComment(threadID: followUp.id, body: "Please split it.", delivery: .sendNow)

            let answer = try fixture.openThread(store, body: "answer").thread
            _ = try store.addAgentReply(threadID: answer.id, status: .question, body: "Whole form or button?", sessionID: nil)
            tick()
            _ = try store.addComment(threadID: answer.id, body: "Just the button.", delivery: .sendNow)

            let reopened = try fixture.openThread(store, body: "reopened").thread
            _ = try store.addAgentReply(threadID: reopened.id, status: .addressed, body: "Done.", sessionID: nil)
            tick()
            try store.resolveThread(threadID: reopened.id)
            try store.reopenThread(threadID: reopened.id)
            tick()
            _ = try store.addComment(threadID: reopened.id, body: "It came back.", delivery: .sendNow)

            let resolved = try fixture.openThread(store, body: "resolved").thread
            try store.resolveThread(threadID: resolved.id)

            let deleted = try fixture.openThread(store, body: "deleted")
            try store.deleteComment(commentID: deleted.comment.id)

            let retracted = try fixture.openThread(store, body: "retracted").thread
            _ = try store.addAgentReply(threadID: retracted.id, status: .addressed, body: "Done.", sessionID: nil)
            tick()
            let oops = try store.addComment(threadID: retracted.id, body: "Oops.", delivery: .sendNow)
            try store.deleteComment(commentID: oops.id)

            let pendingReply = try fixture.openThread(store, body: "pending reply").thread
            _ = try store.addAgentReply(threadID: pendingReply.id, status: .question, body: "Which one?", sessionID: nil)
            tick()
            _ = try store.addComment(threadID: pendingReply.id, body: "Not sent yet.", delivery: .addToReview)

            let otherStack = try store.findOrCreateStack(repoID: fixture.repo.id, StackDescription(
                name: "web-ui", source: .singleBranch, trunkBranch: "main", branches: ["web-ui"])).stack
            #expect(otherStack.id != fixture.stack.id)

            let waiting = try store.threadsWaitingOnAgent(stackID: fixture.stack.id)
            #expect(waiting.map(\.thread.id) == [followUp.id, answer.id, reopened.id, new.id])
            #expect(waiting.map(\.kind) == [.followUp, .answer, .reopened, .new])
            #expect(waiting.map(\.layer.position) == [1, 1, 1, 2])
            #expect(waiting[0].unanswered.map(\.id) == [followUpComment.id])
            #expect(waiting[0].comments.map(\.body) == ["follow-up", "Kept it.", "Please split it."])
            #expect(waiting.allSatisfy { $0.anchor?.state == .original })
            #expect(try store.threadsWaitingOnAgent(stackID: otherStack.id).isEmpty)
        }
    }

    @Test func aCommentSentWithAReviewComesAfterAnAgentReplyWrittenMeanwhile() throws {
        let clock = TestClock()
        try withStore(clock: clock) { store, fixture in
            let thread = try fixture.openThread(store, body: "Use Decimal.").thread
            let pending = try store.addComment(threadID: thread.id, body: "And round half even.", delivery: .addToReview)
            clock.advance(seconds: 1)
            _ = try store.addAgentReply(threadID: thread.id, status: .addressed, body: "Decimal now.", sessionID: nil)
            #expect(try store.threadsWaitingOnAgent(stackID: fixture.stack.id).isEmpty)

            clock.advance(seconds: 1)
            let draft = try store.draftReview(stackID: fixture.stack.id)
            _ = try store.submitReview(reviewID: draft.id, verdict: .comment, body: "", revisionID: fixture.revision.id)
            let waiting = try store.threadsWaitingOnAgent(stackID: fixture.stack.id)
            #expect(waiting.map(\.kind) == [.followUp])
            #expect(waiting.first?.unanswered.map(\.id) == [pending.id])
        }
    }

    @Test func deliveryMarksStayButNeverHideAThread() throws {
        let clock = TestClock()
        try withStore(clock: clock) { store, fixture in
            let session = try store.upsertAgentSession(agent: .claude, sessionKey: "abc", pid: nil, pidStart: nil, cwd: "/tmp/shop")
            let (thread, first) = try fixture.openThread(store, delivery: .addToReview)
            let draft = try store.draftReview(stackID: fixture.stack.id)
            _ = try store.submitReview(reviewID: draft.id, verdict: .changesRequested, body: "", revisionID: fixture.revision.id)

            var waiting = try store.threadsWaitingOnAgent(stackID: fixture.stack.id)
            #expect(waiting.first?.shownBefore == false)
            #expect(waiting.first?.wasShown == false)

            clock.advance(seconds: 1)
            let shownAt = clock.now
            try store.markDelivered(commentIDs: waiting.flatMap(\.unanswered).map(\.id), to: session.id)
            let delivered = try store.review(draft.id)
            #expect(delivered.status == .delivered)
            #expect(delivered.deliveredTo == session.id)
            #expect(delivered.deliveredAt == shownAt)

            waiting = try store.threadsWaitingOnAgent(stackID: fixture.stack.id)
            #expect(waiting.map(\.thread.id) == [thread.id])
            #expect(waiting.first?.shownBefore == true)

            clock.advance(seconds: 1)
            let more = try store.addComment(threadID: thread.id, body: "Also the tax line.", delivery: .sendNow)
            try store.markDelivered(commentIDs: [first.id], to: session.id)
            waiting = try store.threadsWaitingOnAgent(stackID: fixture.stack.id)
            #expect(waiting.first?.unanswered.map(\.id) == [first.id, more.id])
            #expect(waiting.first?.shownBefore == false)
            #expect(waiting.first?.wasShown == true)
            #expect(try store.comment(first.id).deliveredAt == shownAt)
        }
    }

    @Test func theStopHookBlocksOncePerReason() throws {
        try withStore { store, _ in
            let session = try store.upsertAgentSession(agent: .claude, sessionKey: "abc", pid: nil, pidStart: nil, cwd: "/tmp/shop")
            #expect(try store.recordStopBlock(sessionID: session.id, reasonKey: "unreplied:7"))
            #expect(try store.recordStopBlock(sessionID: session.id, reasonKey: "unreplied:7") == false)
            #expect(try store.recordStopBlock(sessionID: session.id, reasonKey: "undelivered:c215"))
            #expect(try store.fetchAll(StopBlockRecord.self).count == 2)
        }
    }
}
