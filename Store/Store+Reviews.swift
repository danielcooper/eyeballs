import Foundation
import GRDB

extension Store {
    /// The stack's draft review, created if it has none. A stack never has two.
    public func draftReview(stackID: Int) throws -> ReviewRecord {
        let now = clock().databaseMilliseconds
        return try pool.write { db in try fetchOrCreateDraft(db, stackID: stackID, now: now) }
    }

    /// Saves the summary you are typing for the stack's draft review.
    @discardableResult
    public func saveDraftSummary(stackID: Int, body: String) throws -> ReviewRecord {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            let draft = try fetchOrCreateDraft(db, stackID: stackID, now: now)
            return try update(ReviewRecord.self, db, id: draft.id, set: "body = ?", arguments: [body])
        }
    }

    /// Submits a draft review: it becomes `submitted`, and every comment in it is sent.
    ///
    /// Deleted comments stay unsent. Throws `StoreError.reviewNotDraft` if the review was
    /// already submitted or discarded, so a double click never sends it twice.
    /// - Parameter revisionID: the revision you were looking at, after any snapshot that
    ///   Submit took because the branch tips moved.
    public func submitReview(reviewID: Int, verdict: ReviewVerdict, body: String, revisionID: Int) throws -> ReviewRecord {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            let review = try existing(ReviewRecord.self, db, id: reviewID)
            guard review.status == .draft else { throw StoreError.reviewNotDraft(reviewID: reviewID) }
            try db.execute(sql: "UPDATE comment SET sent_at = ? WHERE review_id = ? AND sent_at IS NULL AND deleted_at IS NULL",
                           arguments: [now, reviewID])
            return try update(ReviewRecord.self, db, id: reviewID,
                              set: "status = 'submitted', verdict = ?, body = ?, revision_id = ?, submitted_at = ?",
                              arguments: [verdict, body, revisionID, now])
        }
    }
}

func fetchOrCreateDraft(_ db: Database, stackID: Int, now: Int64) throws -> ReviewRecord {
    if let draft = try ReviewRecord.filter(sql: "stack_id = ? AND status = 'draft'", arguments: [stackID]).fetchOne(db) {
        return draft
    }
    return try insert(ReviewRecord.self, db, sql: "INSERT INTO review (stack_id, status, created_at) VALUES (?, 'draft', ?)",
                      arguments: [stackID, now])
}
