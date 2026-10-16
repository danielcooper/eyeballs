import CryptoKit
import Foundation
import GRDB

/// One layer's fixed (base, head) pair and its changed files, for `insertSnapshot`.
public struct SnapshotDescription: Hashable, Sendable {
    public var layerID: Int
    public var baseSHA: String
    public var headSHA: String
    public var baseTree: String
    public var headTree: String
    public var baseRule: BaseRule
    public var parentRef: String
    public var patchID: String?
    public var files: [File]

    public init(layerID: Int, baseSHA: String, headSHA: String, baseTree: String, headTree: String,
                baseRule: BaseRule, parentRef: String, patchID: String? = nil, files: [File]) {
        self.layerID = layerID
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.baseTree = baseTree
        self.headTree = headTree
        self.baseRule = baseRule
        self.parentRef = parentRef
        self.patchID = patchID
        self.files = files
    }

    public struct File: Hashable, Sendable {
        public var path: String
        public var oldPath: String?
        public var change: FileChangeKind
        public var baseBlob: String?
        public var headBlob: String?
        public var filePatch: String?
        /// Nil for a binary file.
        public var additions: Int?
        public var deletions: Int?

        public init(path: String, oldPath: String? = nil, change: FileChangeKind, baseBlob: String? = nil, headBlob: String? = nil,
                    filePatch: String? = nil, additions: Int?, deletions: Int?) {
            self.path = path
            self.oldPath = oldPath
            self.change = change
            self.baseBlob = baseBlob
            self.headBlob = headBlob
            self.filePatch = filePatch
            self.additions = additions
            self.deletions = deletions
        }
    }
}

/// One layer's place in a new revision, for `createRevision`.
public struct RevisionLayerDescription: Hashable, Sendable {
    public var layerID: Int
    /// 1 is the bottom layer.
    public var position: Int
    public var snapshotID: Int

    public init(layerID: Int, position: Int, snapshotID: Int) {
        self.layerID = layerID
        self.position = position
        self.snapshotID = snapshotID
    }
}

extension Store {
    /// Saves a snapshot and its files, or returns the one already saved for the same layer,
    /// base and head.
    public func insertSnapshot(_ snapshot: SnapshotDescription) throws -> SnapshotRecord {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            if let saved = try SnapshotRecord.filter(sql: "layer_id = ? AND base_sha = ? AND head_sha = ?",
                                                     arguments: [snapshot.layerID, snapshot.baseSHA, snapshot.headSHA]).fetchOne(db) {
                return saved
            }
            let record = try insert(SnapshotRecord.self, db, sql: """
                INSERT INTO snapshot (layer_id, base_sha, head_sha, base_tree, head_tree, base_rule, parent_ref, patch_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [snapshot.layerID, snapshot.baseSHA, snapshot.headSHA, snapshot.baseTree, snapshot.headTree,
                                 snapshot.baseRule, snapshot.parentRef, snapshot.patchID, now])
            for file in snapshot.files {
                try db.execute(sql: """
                    INSERT INTO snapshot_file (snapshot_id, path, old_path, change, base_blob, head_blob, file_patch, additions, deletions)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [record.id, file.path, file.oldPath, file.change, file.baseBlob, file.headBlob,
                                     file.filePatch, file.additions, file.deletions])
            }
            return record
        }
    }

    /// Records a revision of the stack, unless nothing changed since the latest one.
    ///
    /// The content hash covers each layer's base and head. When it equals the latest revision's,
    /// no revision is written and the latest one comes back with `created: false`. Otherwise
    /// the new revision gets the next number, and every `addressed` agent reply in the stack
    /// that has no `fixed_in` yet gets this revision.
    public func createRevision(
        stackID: Int,
        trigger: RevisionTrigger,
        layers: [RevisionLayerDescription],
        agentSession: Int? = nil,
        agentNote: String? = nil,
        dirtyFiles: Int = 0
    ) throws -> (revision: RevisionRecord, created: Bool) {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            let hash = try contentHash(db, layers)
            let latest = try fetchLatestRevision(db, stackID: stackID)
            if let latest, latest.contentHash == hash {
                return (latest, false)
            }
            let revision = try insert(RevisionRecord.self, db, sql: """
                INSERT INTO revision (stack_id, number, trigger, content_hash, agent_session, agent_note, dirty_files, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [stackID, (latest?.number ?? 0) + 1, trigger, hash, agentSession, agentNote, dirtyFiles, now])
            for layer in layers {
                try db.execute(sql: "INSERT INTO revision_layer (revision_id, layer_id, position, snapshot_id) VALUES (?, ?, ?, ?)",
                               arguments: [revision.id, layer.layerID, layer.position, layer.snapshotID])
            }
            try db.execute(sql: """
                UPDATE comment SET fixed_in = ?
                WHERE author = 'agent' AND reply_status = 'addressed' AND fixed_in IS NULL
                  AND thread_id IN (SELECT id FROM thread WHERE stack_id = ?)
                """, arguments: [revision.id, stackID])
            return (revision, true)
        }
    }

    /// The stack's newest revision, or nil before the first `eyeballs review`.
    public func latestRevision(stackID: Int) throws -> RevisionRecord? {
        try pool.read { db in try fetchLatestRevision(db, stackID: stackID) }
    }

    /// A SHA-256 over the sorted (layer, base, head) triples.
    private func contentHash(_ db: Database, _ layers: [RevisionLayerDescription]) throws -> String {
        var lines: [String] = []
        for layer in layers.sorted(by: { $0.layerID < $1.layerID }) {
            let snapshot = try existing(SnapshotRecord.self, db, id: layer.snapshotID)
            guard snapshot.layerID == layer.layerID else {
                throw StoreError.snapshotLayerMismatch(snapshotID: snapshot.id, layerID: layer.layerID)
            }
            lines.append("\(layer.layerID) \(snapshot.baseSHA) \(snapshot.headSHA)\n")
        }
        return SHA256.hash(data: Data(lines.joined().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

func fetchLatestRevision(_ db: Database, stackID: Int) throws -> RevisionRecord? {
    try RevisionRecord.filter(sql: "stack_id = ?", arguments: [stackID]).order(sql: "number DESC").fetchOne(db)
}

/// The stack's newest revision, which every new comment records.
func requireLatestRevision(_ db: Database, stackID: Int) throws -> RevisionRecord {
    guard let revision = try fetchLatestRevision(db, stackID: stackID) else {
        throw StoreError.stackHasNoRevision(stackID: stackID)
    }
    return revision
}
