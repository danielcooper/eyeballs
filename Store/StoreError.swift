import Foundation

/// A problem the store found, worded for the person who will read it.
public enum StoreError: Error, Equatable, LocalizedError {
    /// The system SQLite is older than 3.37.0, which STRICT tables need.
    case sqliteTooOld(found: String)
    /// The database file is damaged: SQLite cannot read it, or `PRAGMA quick_check` found problems.
    case damagedDatabase(backups: String)
    /// No row with this ID exists in the table.
    case notFound(table: String, id: Int)
    /// A thread or comment needs a revision of its stack, and the stack has none yet.
    case stackHasNoRevision(stackID: Int)
    /// The review was already submitted or discarded, so it cannot be submitted again.
    case reviewNotDraft(reviewID: Int)
    /// You can only edit or delete your own comments, never an agent's.
    case notYourComment(commentID: Int)
    /// A revision was given a snapshot that belongs to a different layer.
    case snapshotLayerMismatch(snapshotID: Int, layerID: Int)

    public var errorDescription: String? {
        switch self {
        case .sqliteTooOld(let found):
            "Eyeballs needs SQLite 3.37.0 or later for its database, but this Mac has \(found). Update macOS, then open Eyeballs again."
        case .damagedDatabase(let backups):
            "The Eyeballs database is damaged. Quit Eyeballs and restore the newest backup from \(backups)."
        case .notFound(let table, let id):
            "No \(table) with ID \(id) exists."
        case .stackHasNoRevision(let stackID):
            "Stack s\(stackID) has no revision yet. Run eyeballs review first."
        case .reviewNotDraft(let reviewID):
            "Review \(reviewID) is no longer a draft, so it cannot be submitted again."
        case .notYourComment(let commentID):
            "Comment c\(commentID) was written by the agent. You can only edit or delete your own comments."
        case .snapshotLayerMismatch(let snapshotID, let layerID):
            "Snapshot \(snapshotID) belongs to a different layer than layer \(layerID)."
        }
    }
}
