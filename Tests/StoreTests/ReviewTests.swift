@testable import EyeballsStore
import Foundation
import GRDB
import Testing

struct ReviewTests {
    @Test func aStackHasOneDraftReviewAtATime() throws {
        try withStore { store, fixture in
            let draft = try store.draftReview(stackID: fixture.stack.id)
            #expect(try store.draftReview(stackID: fixture.stack.id).id == draft.id)

            let (_, comment) = try fixture.openThread(store, delivery: .addToReview)
            #expect(comment.reviewID == draft.id)
            #expect(comment.sentAt == nil)

            #expect(throws: DatabaseError.self) {
                try store.pool.write { db in
                    try db.execute(sql: "INSERT INTO review (stack_id, status, created_at) VALUES (?, 'draft', 0)", arguments: [fixture.stack.id])
                }
            }

            _ = try store.submitReview(reviewID: draft.id, verdict: .comment, body: "", revisionID: fixture.revision.id)
            let next = try store.draftReview(stackID: fixture.stack.id)
            #expect(next.id != draft.id)
            #expect(next.status == .draft)
        }
    }

    @Test func eachStackHasItsOwnDraft() throws {
        try withStore { store, fixture in
            let other = try store.findOrCreateStack(repoID: fixture.repo.id, StackDescription(
                name: "web-ui", source: .singleBranch, trunkBranch: "main", branches: ["web-ui"]))
            #expect(other.created)
            #expect(try store.draftReview(stackID: other.stack.id).id != store.draftReview(stackID: fixture.stack.id).id)
        }
    }

    @Test func submittingSendsEveryLiveCommentInTheReview() throws {
        let clock = TestClock()
        try withStore(clock: clock) { store, fixture in
            let first = try fixture.openThread(store, body: "Use Decimal.", delivery: .addToReview)
            let second = try fixture.openThread(store, layer: 1, body: "Only retry 5xx.", delivery: .addToReview)
            let deleted = try store.addComment(threadID: second.thread.id, body: "Never mind.", delivery: .addToReview)
            try store.deleteComment(commentID: deleted.id)
            let summary = try store.saveDraftSummary(stackID: fixture.stack.id, body: "Close. Mostly naming.")

            clock.advance(seconds: 30)
            let submitted = try store.submitReview(reviewID: summary.id, verdict: .changesRequested, body: summary.body,
                                                   revisionID: fixture.revision.id)
            #expect(submitted.status == .submitted)
            #expect(submitted.verdict == .changesRequested)
            #expect(submitted.body == "Close. Mostly naming.")
            #expect(submitted.revisionID == fixture.revision.id)
            #expect(submitted.submittedAt == clock.now)

            #expect(try store.comment(first.comment.id).sentAt == clock.now)
            #expect(try store.comment(second.comment.id).sentAt == clock.now)
            #expect(try store.comment(deleted.id).sentAt == nil)
        }
    }

    @Test func aReviewIsSubmittedOnlyOnce() throws {
        try withStore { store, fixture in
            try fixture.openThread(store, delivery: .addToReview)
            let draft = try store.draftReview(stackID: fixture.stack.id)
            _ = try store.submitReview(reviewID: draft.id, verdict: .comment, body: "", revisionID: fixture.revision.id)
            #expect(throws: StoreError.reviewNotDraft(reviewID: draft.id)) {
                _ = try store.submitReview(reviewID: draft.id, verdict: .approved, body: "", revisionID: fixture.revision.id)
            }
            #expect(try store.review(draft.id).verdict == .comment)
        }
    }

    @Test func sendNowSkipsTheDraft() throws {
        let clock = TestClock()
        try withStore(clock: clock) { store, fixture in
            let (_, comment) = try fixture.openThread(store, delivery: .sendNow)
            #expect(comment.reviewID == nil)
            #expect(comment.sentAt == clock.now)
            #expect(try store.fetchAll(ReviewRecord.self).isEmpty)
        }
    }

    @Test func aReviewIsRepliedOnceTheAgentAnswersEveryThreadInIt() throws {
        try withStore { store, fixture in
            let first = try fixture.openThread(store, delivery: .addToReview)
            let second = try fixture.openThread(store, layer: 1, delivery: .addToReview)
            let draft = try store.draftReview(stackID: fixture.stack.id)
            _ = try store.submitReview(reviewID: draft.id, verdict: .changesRequested, body: "", revisionID: fixture.revision.id)
            try store.markDelivered(commentIDs: [first.comment.id, second.comment.id], to: nil)
            #expect(try store.review(draft.id).status == .delivered)

            _ = try store.addAgentReply(threadID: first.thread.id, status: .addressed, body: "Done.", sessionID: nil)
            #expect(try store.review(draft.id).status == .delivered)
            _ = try store.addAgentReply(threadID: second.thread.id, status: .question, body: "5xx only?", sessionID: nil)
            let replied = try store.review(draft.id)
            #expect(replied.status == .replied)
            #expect(replied.repliedAt != nil)
        }
    }
}
