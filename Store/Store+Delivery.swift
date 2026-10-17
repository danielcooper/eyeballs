import Foundation
import GRDB

/// A thread that waits on the agent: it is open and not deleted, and the last comment sent in
/// it is yours.
public struct WaitingThread: Hashable, Sendable {
    public var thread: ThreadRecord
    public var layer: LayerRecord
    /// The thread's newest anchor, from the latest revision it was ported to.
    public var anchor: AnchorRecord?
    public var kind: AgentThreadKind
    /// Every comment the agent may see: sent and not deleted, in the order they were sent.
    public var comments: [CommentRecord]
    /// Your comments since the agent's last reply. These are what the agent has to answer.
    public var unanswered: [CommentRecord]

    /// True when `eyeballs inbox` already showed every unanswered comment.
    /// The packet labels these threads `shown before`.
    public var shownBefore: Bool { unanswered.allSatisfy { $0.deliveredAt != nil } }

    /// True when `eyeballs inbox` showed at least one unanswered comment, so a new
    /// `eyeballs review` must not skip it without `--force`.
    public var wasShown: Bool { unanswered.contains { $0.deliveredAt != nil } }
}

extension Store {
    /// Every thread in the stack that waits on the agent, bottom layer first, then by path and line.
    ///
    /// Resolved and deleted threads never wait, and neither do comments still in your draft.
    /// Threads `inbox` showed before are included, so an interrupted `inbox` hides nothing.
    public func threadsWaitingOnAgent(stackID: Int) throws -> [WaitingThread] {
        try pool.read { db in
            let threads = try ThreadRecord
                .filter(sql: "stack_id = ? AND status = 'open' AND deleted_at IS NULL", arguments: [stackID])
                .fetchAll(db)
            let threadIDs = threads.map(\.id)
            let comments = try Dictionary(grouping: CommentRecord
                .filter(threadIDs.contains(Column("thread_id")))
                .filter(sql: "deleted_at IS NULL AND sent_at IS NOT NULL")
                .fetchAll(db), by: \.threadID)
            let layers = try Dictionary(uniqueKeysWithValues: LayerRecord
                .filter(Set(threads.map(\.layerID)).contains(Column("id")))
                .fetchAll(db).map { ($0.id, $0) })
            let anchors = try newestAnchors(db, threadIDs: threadIDs)

            let waiting = threads.compactMap { thread -> WaitingThread? in
                let sent = (comments[thread.id] ?? []).sorted(by: ThreadProgress.sentOrder)
                guard let kind = ThreadProgress(thread: thread, comments: sent).agentKind, let layer = layers[thread.layerID] else {
                    return nil
                }
                let unanswered = Array(sent.reversed().prefix { $0.author == .human }.reversed())
                return WaitingThread(thread: thread, layer: layer, anchor: anchors[thread.id], kind: kind,
                                     comments: sent, unanswered: unanswered)
            }
            return waiting.sorted(by: Self.packetOrder)
        }
    }

    /// Records that `eyeballs inbox` showed these comments to `sessionID`.
    ///
    /// Each comment keeps the first time it was shown. A submitted review that holds any of them
    /// becomes `delivered`. This only stops repeat wake-ups; it never hides a thread.
    public func markDelivered(commentIDs: [Int], to sessionID: Int?) throws {
        guard !commentIDs.isEmpty else { return }
        let now = clock().databaseMilliseconds
        let ids = databaseQuestionMarks(count: commentIDs.count)
        try pool.write { db in
            try db.execute(sql: "UPDATE comment SET delivered_at = ? WHERE delivered_at IS NULL AND id IN (\(ids))",
                           arguments: [now] + StatementArguments(commentIDs))
            try db.execute(sql: """
                UPDATE review SET status = 'delivered', delivered_at = ?, delivered_to = ?
                WHERE status = 'submitted' AND id IN (SELECT review_id FROM comment WHERE id IN (\(ids)))
                """, arguments: [now, sessionID] + StatementArguments(commentIDs))
        }
    }

    /// Records that `eyeballs inbox` showed these submitted reviews to `sessionID`.
    ///
    /// A review with no comments of its own, such as an approval, only becomes `delivered` this
    /// way, because `markDelivered(commentIDs:to:)` reaches reviews through their comments.
    public func markReviewsDelivered(reviewIDs: [Int], to sessionID: Int?) throws {
        guard !reviewIDs.isEmpty else { return }
        let now = clock().databaseMilliseconds
        try pool.write { db in
            try db.execute(sql: """
                UPDATE review SET status = 'delivered', delivered_at = ?, delivered_to = ?
                WHERE status = 'submitted' AND id IN (\(databaseQuestionMarks(count: reviewIDs.count)))
                """, arguments: [now, sessionID] + StatementArguments(reviewIDs))
        }
    }

    /// Records that the Stop hook blocked this session for `reasonKey`, such as `unreplied:7`.
    ///
    /// - Returns: true the first time, when the hook should block. False when it already
    ///   blocked for this reason, so it must let the agent stop.
    public func recordStopBlock(sessionID: Int, reasonKey: String) throws -> Bool {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            try db.execute(sql: "INSERT INTO stop_block (session_id, reason_key, blocked_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                           arguments: [sessionID, reasonKey, now])
            return db.changesCount == 1
        }
    }

    private func newestAnchors(_ db: Database, threadIDs: [Int]) throws -> [Int: AnchorRecord] {
        guard !threadIDs.isEmpty else { return [:] }
        let anchors = try AnchorRecord.fetchAll(db, sql: """
            SELECT * FROM anchor
            WHERE thread_id IN (\(databaseQuestionMarks(count: threadIDs.count)))
            ORDER BY thread_id, revision_id, id
            """, arguments: StatementArguments(threadIDs))
        return Dictionary(anchors.map { ($0.threadID, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    /// Bottom layer first, then layer threads, then by path and line.
    private static func packetOrder(_ a: WaitingThread, _ b: WaitingThread) -> Bool {
        (a.layer.position, a.anchor?.path ?? "", a.anchor?.startLine ?? 0, a.thread.id)
            < (b.layer.position, b.anchor?.path ?? "", b.anchor?.startLine ?? 0, b.thread.id)
    }
}
