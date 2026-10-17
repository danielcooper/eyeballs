import EyeballsStore
import Foundation
import GRDB

/// Everything the store holds about one stack, read in one transaction, so a packet or the
/// window never mixes two moments.
struct StackFacts: Sendable {
    var stack: StackRecord
    var repo: RepoRecord
    /// Every layer the stack has had, by ID. A thread keeps its home layer after the layer ends.
    var layers: [Int: LayerRecord]
    /// The layers in the stack now, bottom first.
    var activeLayers: [LayerRecord]
    /// Oldest first.
    var revisions: [RevisionRecord]
    /// For each revision ID, the snapshot ID of each layer ID.
    var revisionSnapshots: [Int: [Int: Int]]
    var snapshots: [Int: SnapshotRecord]
    /// Threads that are not deleted, oldest first.
    var threads: [ThreadRecord]
    /// Each thread's comments that are not deleted, in the order they reached the other side.
    var comments: [Int: [CommentRecord]]
    /// Each thread's anchors, oldest first.
    var anchors: [Int: [AnchorRecord]]
    /// Newest first.
    var reviews: [ReviewRecord]
    var sessions: [Int: AgentSessionRecord]
    var editedCommentIDs: Set<Int>

    var latestRevision: RevisionRecord? { revisions.last }
    var driver: AgentSessionRecord? { stack.driverSession.flatMap { sessions[$0] } }

    func revision(id: Int) -> RevisionRecord? {
        revisions.first { $0.id == id }
    }

    /// The `r` number of a revision, such as 4 for r4.
    func number(ofRevision id: Int) -> Int {
        revision(id: id)?.number ?? 0
    }

    func snapshot(layerID: Int, revisionID: Int) -> SnapshotRecord? {
        revisionSnapshots[revisionID]?[layerID].flatMap { snapshots[$0] }
    }

    func progress(of thread: ThreadRecord) -> ThreadProgress {
        ThreadProgress(thread: thread, comments: comments[thread.id] ?? [])
    }

    /// Comments the agent may see: sent ones only.
    func sentComments(of thread: ThreadRecord) -> [CommentRecord] {
        (comments[thread.id] ?? []).filter { $0.sentAt != nil }
    }

    /// Where the thread sits at `revisionID`: the newest anchor written for that revision, or else
    /// the newest one before it. Nil only for a thread written after that revision.
    func anchor(of thread: ThreadRecord, at revisionID: Int) -> AnchorRecord? {
        let anchors = anchors[thread.id] ?? []
        return anchors.last { $0.revisionID == revisionID } ?? anchors.last { $0.revisionID < revisionID }
    }

    /// The thread's newest anchor.
    func newestAnchor(of thread: ThreadRecord) -> AnchorRecord? {
        anchors[thread.id]?.last
    }

    /// The anchor the thread was written on.
    func origin(of thread: ThreadRecord) -> AnchorRecord? {
        anchors[thread.id]?.first { $0.method == .created } ?? anchors[thread.id]?.first
    }

    /// The anchor before `anchor` that a port could start from, for "Moved from line 98".
    func goodAnchor(before anchor: AnchorRecord, of thread: ThreadRecord) -> AnchorRecord? {
        (anchors[thread.id] ?? []).last { $0.id < anchor.id && $0.revisionID < anchor.revisionID && ($0.state.isGood || $0.method == .human) }
    }

    /// The draft review, if the stack has one.
    var draftReview: ReviewRecord? {
        reviews.first { $0.status == .draft }
    }

    /// Your comments waiting in the draft review, in threads that are not deleted.
    var pendingComments: [CommentRecord] {
        guard let draft = draftReview else { return [] }
        let all: [CommentRecord] = threads.flatMap { thread -> [CommentRecord] in comments[thread.id] ?? [] }
        return all.filter { comment in comment.reviewID == draft.id && comment.sentAt == nil && comment.author == .human }
    }

    /// The newest review you submitted.
    var lastSubmittedReview: ReviewRecord? {
        reviews.first { $0.status != .draft && $0.status != .discarded && $0.submittedAt != nil }
    }
}

extension Store {
    /// Everything about one stack, or nil when there is no such stack.
    func facts(stackID: Int) throws -> StackFacts? {
        try reader.read { db in
            guard let stack = try StackRecord.fetchOne(db, id: stackID),
                  let repo = try RepoRecord.fetchOne(db, id: stack.repoID) else { return nil }
            let layers = try LayerRecord.filter(sql: "stack_id = ?", arguments: [stackID]).order(sql: "position, id").fetchAll(db)
            let revisions = try RevisionRecord.filter(sql: "stack_id = ?", arguments: [stackID]).order(sql: "number").fetchAll(db)
            let revisionLayers = try RevisionLayerRecord.fetchAll(db, sql: """
                SELECT revision_layer.* FROM revision_layer JOIN revision ON revision.id = revision_layer.revision_id
                WHERE revision.stack_id = ?
                """, arguments: [stackID])
            let snapshots = try SnapshotRecord.fetchAll(db, sql: """
                SELECT * FROM snapshot WHERE layer_id IN (SELECT id FROM layer WHERE stack_id = ?)
                """, arguments: [stackID])
            let threads = try ThreadRecord.filter(sql: "stack_id = ? AND deleted_at IS NULL", arguments: [stackID]).order(sql: "id").fetchAll(db)
            let threadIDs = threads.map(\.id)
            let comments = try CommentRecord
                .filter(threadIDs.contains(Column("thread_id")))
                .filter(sql: "deleted_at IS NULL")
                .fetchAll(db)
            let anchors = try AnchorRecord
                .filter(threadIDs.contains(Column("thread_id")))
                .order(sql: "revision_id, id")
                .fetchAll(db)
            let reviews = try ReviewRecord.filter(sql: "stack_id = ?", arguments: [stackID]).order(sql: "id DESC").fetchAll(db)
            let commentIDs = comments.map(\.id)
            let edited = try CommentEditRecord
                .select(Column("comment_id"), as: Int.self)
                .filter(commentIDs.contains(Column("comment_id")))
                .fetchAll(db)
            var sessionIDs = Set(comments.compactMap(\.agentSession))
            if let driver = stack.driverSession { sessionIDs.insert(driver) }
            let sessions = try AgentSessionRecord.filter(sessionIDs.contains(Column("id"))).fetchAll(db)

            var snapshotsByRevision: [Int: [Int: Int]] = [:]
            for row in revisionLayers { snapshotsByRevision[row.revisionID, default: [:]][row.layerID] = row.snapshotID }
            return StackFacts(
                stack: stack,
                repo: repo,
                layers: Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) }),
                activeLayers: layers.filter { $0.state == .active },
                revisions: revisions,
                revisionSnapshots: snapshotsByRevision,
                snapshots: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) }),
                threads: threads,
                comments: Dictionary(grouping: comments, by: \.threadID).mapValues { $0.sorted(by: Self.sentOrder) },
                anchors: Dictionary(grouping: anchors, by: \.threadID),
                reviews: reviews,
                sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }),
                editedCommentIDs: Set(edited))
        }
    }

    /// Comments in the order they reached the other side. A comment still in your draft comes last.
    static func sentOrder(_ a: CommentRecord, _ b: CommentRecord) -> Bool {
        (a.sentAt ?? .distantFuture, a.id) < (b.sentAt ?? .distantFuture, b.id)
    }

    /// Every active stack, the one with the newest revision first.
    func activeStacks() throws -> [StackRecord] {
        try reader.read { db in
            try StackRecord.fetchAll(db, sql: """
                SELECT stack.* FROM stack
                WHERE state = 'active'
                ORDER BY (SELECT MAX(created_at) FROM revision WHERE revision.stack_id = stack.id) DESC, id DESC
                """)
        }
    }

    func stack(id: Int) throws -> StackRecord? {
        try reader.read { try StackRecord.fetchOne($0, id: id) }
    }

    func repo(id: Int) throws -> RepoRecord? {
        try reader.read { try RepoRecord.fetchOne($0, id: id) }
    }

    func repo(commonDir: String) throws -> RepoRecord? {
        try reader.read { try RepoRecord.filter(sql: "common_dir = ?", arguments: [commonDir]).fetchOne($0) }
    }

    func repos() throws -> [RepoRecord] {
        try reader.read { try RepoRecord.order(sql: "id").fetchAll($0) }
    }

    /// Active stacks in a repo that have `branch` as an active layer.
    func activeStacks(containing branch: String, repoID: Int) throws -> [StackRecord] {
        try reader.read { db in
            try StackRecord.fetchAll(db, sql: """
                SELECT * FROM stack WHERE repo_id = ? AND state = 'active'
                  AND id IN (SELECT stack_id FROM layer WHERE state = 'active' AND branch = ?)
                ORDER BY id DESC
                """, arguments: [repoID, branch])
        }
    }

    func activeLayers(stackID: Int) throws -> [LayerRecord] {
        try reader.read { db in
            try LayerRecord.filter(sql: "stack_id = ? AND state = 'active'", arguments: [stackID]).order(sql: "position").fetchAll(db)
        }
    }

    func session(id: Int) throws -> AgentSessionRecord? {
        try reader.read { try AgentSessionRecord.fetchOne($0, id: id) }
    }

    func session(agent: AgentKind, key: String) throws -> AgentSessionRecord? {
        try reader.read { db in
            try AgentSessionRecord.filter(sql: "agent = ? AND session_key = ?", arguments: [agent.rawValue, key]).fetchOne(db)
        }
    }

    /// Sessions whose Claude process is one of `pids`, newest first.
    func sessions(withProcessIn pids: [Int32]) throws -> [AgentSessionRecord] {
        guard !pids.isEmpty else { return [] }
        let values = pids.map { Int($0) }
        return try reader.read { db in
            try AgentSessionRecord.filter(values.contains(Column("pid"))).order(sql: "last_seen DESC").fetchAll(db)
        }
    }

    /// Active stacks this session drives, the newest first.
    func stacksDriven(bySession sessionID: Int) throws -> [StackRecord] {
        try reader.read { db in
            try StackRecord.filter(sql: "driver_session = ? AND state = 'active'", arguments: [sessionID]).order(sql: "id DESC").fetchAll(db)
        }
    }

    /// The changed files of each snapshot.
    func files(ofSnapshots ids: [Int]) throws -> [Int: [SnapshotFileRecord]] {
        guard !ids.isEmpty else { return [:] }
        return try reader.read { db in
            let rows = try SnapshotFileRecord.filter(ids.contains(Column("snapshot_id"))).order(sql: "path").fetchAll(db)
            return Dictionary(grouping: rows, by: \.snapshotID)
        }
    }

    /// The snapshot already saved for this layer, base and head.
    func snapshot(layerID: Int, base: String, head: String) throws -> SnapshotRecord? {
        try reader.read { db in
            try SnapshotRecord.filter(sql: "layer_id = ? AND base_sha = ? AND head_sha = ?", arguments: [layerID, base, head]).fetchOne(db)
        }
    }

    func thread(id: Int) throws -> ThreadRecord? {
        try reader.read { try ThreadRecord.fetchOne($0, id: id) }
    }

    func threads(ids: [Int]) throws -> [ThreadRecord] {
        guard !ids.isEmpty else { return [] }
        return try reader.read { try ThreadRecord.filter(ids.contains(Column("id"))).fetchAll($0) }
    }
}
