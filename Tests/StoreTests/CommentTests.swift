@testable import EyeballsStore
import Foundation
import GRDB
import Testing

struct CommentTests {
    @Test func createThreadWritesTheOriginAnchorAndFirstComment() throws {
        try withStore { store, fixture in
            let created = try store.createThread(subject: .line, side: .head, origin: fixture.anchor(layer: 1), body: "Only retry 5xx.",
                                                 delivery: .sendNow)
            #expect(created.thread.stackID == fixture.stack.id)
            #expect(created.thread.layerID == fixture.layers[1].id)
            #expect(created.thread.status == .open)
            #expect(created.thread.openedBy == .human)
            #expect(created.anchor.state == .original)
            #expect(created.anchor.method == .created)
            #expect(created.anchor.startLine == 12)
            #expect(created.anchor.endLine == 14)
            #expect(created.anchor.inDiff)
            #expect(created.comment.author == .human)
            #expect(created.comment.revisionID == fixture.revision.id)

            #expect(throws: DatabaseError.self) {
                _ = try store.addAnchor(threadID: created.thread.id, fixture.anchor(layer: 1), state: .original, method: .created,
                                        verified: true, portedFrom: nil)
            }
        }
    }

    @Test func anEditKeepsTheOldText() throws {
        let clock = TestClock()
        try withStore(clock: clock) { store, fixture in
            let (_, comment) = try fixture.openThread(store, body: "Use Decimal.")
            clock.advance(seconds: 5)
            let edited = try store.editComment(commentID: comment.id, body: "Use Decimal for money, not Double.")
            #expect(edited.body == "Use Decimal for money, not Double.")
            #expect(edited.updatedAt == clock.now)

            _ = try store.editComment(commentID: comment.id, body: "Use Decimal for money, not Double.")
            let edits = try store.fetchAll(CommentEditRecord.self)
            #expect(edits.map(\.oldBody) == ["Use Decimal."])
            #expect(edits.first?.commentID == comment.id)
        }
    }

    @Test func deletingIsSoftAndCanBeUndone() throws {
        try withStore { store, fixture in
            let (thread, first) = try fixture.openThread(store, body: "First.")
            let second = try store.addComment(threadID: thread.id, body: "Second.", delivery: .sendNow)

            try store.deleteComment(commentID: second.id)
            #expect(try store.comment(second.id).deletedAt != nil)
            #expect(try store.comment(second.id).body == "Second.")
            #expect(try store.thread(thread.id).deletedAt == nil)

            try store.deleteComment(commentID: first.id)
            #expect(try store.thread(thread.id).deletedAt != nil)

            try store.restoreComment(commentID: first.id)
            #expect(try store.comment(first.id).deletedAt == nil)
            #expect(try store.thread(thread.id).deletedAt == nil)
            #expect(try store.fetchAll(CommentRecord.self).count == 2)
        }
    }

    @Test func youCannotEditOrDeleteTheAgentsComments() throws {
        try withStore { store, fixture in
            let (thread, _) = try fixture.openThread(store)
            let reply = try store.addAgentReply(threadID: thread.id, status: .addressed, body: "Done.", sessionID: nil)
            #expect(throws: StoreError.notYourComment(commentID: reply.id)) {
                try store.editComment(commentID: reply.id, body: "Rewritten.")
            }
            #expect(throws: StoreError.notYourComment(commentID: reply.id)) {
                try store.deleteComment(commentID: reply.id)
            }
        }
    }

    @Test func agentRepliesCarryTheirStatusAndRanges() throws {
        let clock = TestClock()
        try withStore(clock: clock) { store, fixture in
            let session = try store.upsertAgentSession(agent: .claude, sessionKey: "abc", pid: 4242, pidStart: 1_760_620_000, cwd: "/tmp/shop")
            let (thread, _) = try fixture.openThread(store)
            let reply = try store.addAgentReply(threadID: thread.id, status: .addressed, body: "Fixed in Retry.swift.",
                                                atRanges: [AtRange(path: "Sources/API/Retry.swift", start: 1, end: 30)], sessionID: session.id)
            #expect(reply.author == .agent)
            #expect(reply.replyStatus == .addressed)
            #expect(reply.agentSession == session.id)
            #expect(reply.reviewID == nil)
            #expect(reply.sentAt == clock.now)
            #expect(reply.atRanges == [AtRange(path: "Sources/API/Retry.swift", start: 1, end: 30)])
        }
    }

    @Test func resolveAndReopen() throws {
        try withStore { store, fixture in
            let (thread, _) = try fixture.openThread(store)
            let resolved = try store.resolveThread(threadID: thread.id)
            #expect(resolved.status == .resolved)
            #expect(resolved.resolvedRevisionID == fixture.revision.id)

            let reopened = try store.reopenThread(threadID: thread.id)
            #expect(reopened.status == .open)
            #expect(reopened.resolvedAt == resolved.resolvedAt)
            #expect(reopened.resolvedRevisionID == fixture.revision.id)

            _ = try store.addAgentReply(threadID: thread.id, status: .declined, body: "Kept.", sessionID: nil)
            try store.resolveThread(threadID: thread.id)
            let late = try store.addAgentReply(threadID: thread.id, status: .addressed, body: "Saved anyway.", sessionID: nil)
            #expect(late.body == "Saved anyway.")
        }
    }
}
