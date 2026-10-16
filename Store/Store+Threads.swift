import Foundation
import GRDB

/// Where a thread sits in one revision, and the text it covers.
public struct NewAnchor: Hashable, Sendable {
    public var revisionID: Int
    public var snapshotID: Int
    public var layerID: Int
    /// Nil for a thread on the whole layer, or when the file is gone.
    public var path: String?
    public var blob: String?
    /// 1-based and inclusive. Nil for a file or layer thread, or when outdated.
    public var lines: ClosedRange<Int>?
    public var inDiff: Bool
    public var coveredText: String?
    public var contextBefore: String?
    public var contextAfter: String?
    public var diffHunk: String?
    public var engineVersion: Int

    public init(revisionID: Int, snapshotID: Int, layerID: Int, path: String? = nil, blob: String? = nil,
                lines: ClosedRange<Int>? = nil, inDiff: Bool, coveredText: String? = nil, contextBefore: String? = nil,
                contextAfter: String? = nil, diffHunk: String? = nil, engineVersion: Int) {
        self.revisionID = revisionID
        self.snapshotID = snapshotID
        self.layerID = layerID
        self.path = path
        self.blob = blob
        self.lines = lines
        self.inDiff = inDiff
        self.coveredText = coveredText
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.diffHunk = diffHunk
        self.engineVersion = engineVersion
    }
}

/// How a comment of yours goes out.
public enum CommentDelivery: Hashable, Sendable {
    /// Into the stack's draft review, sent when you submit it.
    case addToReview
    /// At once, on its own. The design calls this Send now.
    case sendNow
}

extension Store {
    /// Opens a thread with its origin anchor and your first comment.
    ///
    /// The anchor's layer is the thread's home layer. A comment added to the review lands in the
    /// stack's draft review, which is created if needed.
    public func createThread(
        subject: ThreadSubject,
        side: DiffSide?,
        origin: NewAnchor,
        body: String,
        delivery: CommentDelivery
    ) throws -> (thread: ThreadRecord, anchor: AnchorRecord, comment: CommentRecord) {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            let layer = try existing(LayerRecord.self, db, id: origin.layerID)
            let thread = try insert(ThreadRecord.self, db, sql: """
                INSERT INTO thread (stack_id, layer_id, subject, side, created_at) VALUES (?, ?, ?, ?, ?)
                """, arguments: [layer.stackID, layer.id, subject, side, now])
            let anchor = try insertAnchor(db, threadID: thread.id, origin, state: .original, method: .created,
                                          confidence: 1, verified: true, nearLine: nil, portedFrom: nil, now: now)
            let comment = try insertHumanComment(db, thread: thread, body: body, delivery: delivery, now: now)
            return (thread, anchor, comment)
        }
    }

    /// Adds a ported or moved anchor. Anchors are never changed once written.
    ///
    /// The database allows one ported anchor per thread per revision, plus any number with
    /// method `human` from Move here.
    public func addAnchor(
        threadID: Int,
        _ placement: NewAnchor,
        state: AnchorState,
        method: AnchorMethod,
        confidence: Double = 1,
        verified: Bool,
        nearLine: Int? = nil,
        portedFrom: Int?
    ) throws -> AnchorRecord {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            try insertAnchor(db, threadID: threadID, placement, state: state, method: method, confidence: confidence,
                             verified: verified, nearLine: nearLine, portedFrom: portedFrom, now: now)
        }
    }

    /// Adds your reply to a thread, either to the draft review or sent at once.
    public func addComment(threadID: Int, body: String, delivery: CommentDelivery) throws -> CommentRecord {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            let thread = try existing(ThreadRecord.self, db, id: threadID)
            return try insertHumanComment(db, thread: thread, body: body, delivery: delivery, now: now)
        }
    }

    /// Saves the agent's reply. It is sent at once, even on a resolved thread, so agent text is never lost.
    ///
    /// When this reply means every thread in a submitted review now has a newer agent reply,
    /// that review becomes `replied`.
    public func addAgentReply(threadID: Int, status: AgentReplyStatus, body: String, atRanges: [AtRange] = [], sessionID: Int?) throws -> CommentRecord {
        let now = clock().databaseMilliseconds
        let ranges = atRanges.isEmpty ? nil : String(decoding: try JSONEncoder().encode(atRanges), as: UTF8.self)
        return try pool.write { db in
            let thread = try existing(ThreadRecord.self, db, id: threadID)
            let revision = try requireLatestRevision(db, stackID: thread.stackID)
            let comment = try insert(CommentRecord.self, db, sql: """
                INSERT INTO comment (thread_id, author, agent_session, reply_status, body, at_ranges, revision_id, sent_at, created_at, updated_at)
                VALUES (?, 'agent', ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [threadID, sessionID, status, body, ranges, revision.id, now, now, now])
            try markRepliedReviews(db, threadID: threadID, now: now)
            return comment
        }
    }

    /// Changes the text of one of your comments, keeping the old text in `comment_edit`.
    @discardableResult
    public func editComment(commentID: Int, body: String) throws -> CommentRecord {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            let comment = try yourComment(db, id: commentID)
            guard comment.body != body else { return comment }
            try db.execute(sql: "INSERT INTO comment_edit (comment_id, old_body, replaced_at) VALUES (?, ?, ?)",
                           arguments: [commentID, comment.body, now])
            return try update(CommentRecord.self, db, id: commentID, set: "body = ?, updated_at = ?", arguments: [body, now])
        }
    }

    /// Hides one of your comments. Nothing is erased, so `restoreComment` undoes it.
    ///
    /// When no live comment is left in the thread, the thread is deleted too.
    public func deleteComment(commentID: Int) throws {
        let now = clock().databaseMilliseconds
        try pool.write { db in
            let comment = try yourComment(db, id: commentID)
            try db.execute(sql: "UPDATE comment SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                           arguments: [now, now, commentID])
            try db.execute(sql: """
                UPDATE thread SET deleted_at = ?
                WHERE id = ? AND deleted_at IS NULL
                  AND NOT EXISTS (SELECT 1 FROM comment WHERE thread_id = thread.id AND deleted_at IS NULL)
                """, arguments: [now, comment.threadID])
        }
    }

    /// Undoes `deleteComment`, bringing back the comment and its thread.
    public func restoreComment(commentID: Int) throws {
        let now = clock().databaseMilliseconds
        try pool.write { db in
            let comment = try yourComment(db, id: commentID)
            try db.execute(sql: "UPDATE comment SET deleted_at = NULL, updated_at = ? WHERE id = ?", arguments: [now, commentID])
            try db.execute(sql: "UPDATE thread SET deleted_at = NULL WHERE id = ?", arguments: [comment.threadID])
        }
    }

    /// Resolves a thread at the stack's newest revision. Only you do this, from the window.
    @discardableResult
    public func resolveThread(threadID: Int) throws -> ThreadRecord {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            let thread = try existing(ThreadRecord.self, db, id: threadID)
            let revision = try requireLatestRevision(db, stackID: thread.stackID)
            return try update(ThreadRecord.self, db, id: threadID, set: "status = 'resolved', resolved_at = ?, resolved_revision_id = ?",
                              arguments: [now, revision.id])
        }
    }

    /// Reopens a resolved thread. It keeps `resolved_at` and `resolved_revision_id`, because a
    /// reopened thread ports from the revision it was resolved at.
    @discardableResult
    public func reopenThread(threadID: Int) throws -> ThreadRecord {
        try pool.write { db in
            try update(ThreadRecord.self, db, id: threadID, set: "status = 'open'", arguments: [])
        }
    }

    private func insertAnchor(
        _ db: Database, threadID: Int, _ placement: NewAnchor, state: AnchorState, method: AnchorMethod,
        confidence: Double, verified: Bool, nearLine: Int?, portedFrom: Int?, now: Int64
    ) throws -> AnchorRecord {
        try insert(AnchorRecord.self, db, sql: """
            INSERT INTO anchor (thread_id, revision_id, snapshot_id, layer_id, path, blob, start_line, end_line, near_line,
                                state, method, confidence, verified, in_diff, covered_text, context_before, context_after,
                                diff_hunk, ported_from, engine_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [threadID, placement.revisionID, placement.snapshotID, placement.layerID, placement.path, placement.blob,
                             placement.lines?.lowerBound, placement.lines?.upperBound, nearLine, state, method, confidence,
                             verified, placement.inDiff, placement.coveredText, placement.contextBefore, placement.contextAfter,
                             placement.diffHunk, portedFrom, placement.engineVersion, now])
    }

    private func insertHumanComment(_ db: Database, thread: ThreadRecord, body: String, delivery: CommentDelivery, now: Int64) throws -> CommentRecord {
        let revision = try requireLatestRevision(db, stackID: thread.stackID)
        let reviewID: Int? = switch delivery {
        case .addToReview: try fetchOrCreateDraft(db, stackID: thread.stackID, now: now).id
        case .sendNow: nil
        }
        let sentAt: Int64? = delivery == .sendNow ? now : nil
        return try insert(CommentRecord.self, db, sql: """
            INSERT INTO comment (thread_id, author, review_id, body, revision_id, sent_at, created_at, updated_at)
            VALUES (?, 'human', ?, ?, ?, ?, ?, ?)
            """, arguments: [thread.id, reviewID, body, revision.id, sentAt, now, now])
    }

    private func yourComment(_ db: Database, id: Int) throws -> CommentRecord {
        let comment = try existing(CommentRecord.self, db, id: id)
        guard comment.author == .human else { throw StoreError.notYourComment(commentID: id) }
        return comment
    }

    /// A submitted review is replied once every thread it commented on has an agent reply
    /// sent after your comment there.
    private func markRepliedReviews(_ db: Database, threadID: Int, now: Int64) throws {
        try db.execute(sql: """
            UPDATE review SET status = 'replied', replied_at = ?
            WHERE status IN ('submitted', 'delivered')
              AND id IN (SELECT review_id FROM comment WHERE thread_id = ? AND review_id IS NOT NULL AND deleted_at IS NULL)
              AND NOT EXISTS (
                SELECT 1 FROM comment mine
                WHERE mine.review_id = review.id AND mine.deleted_at IS NULL
                  AND NOT EXISTS (
                    SELECT 1 FROM comment reply
                    WHERE reply.thread_id = mine.thread_id AND reply.author = 'agent' AND reply.deleted_at IS NULL
                      AND (reply.sent_at, reply.id) > (mine.sent_at, mine.id)))
            """, arguments: [now, threadID])
    }
}
