import Foundation
import GRDB

/// A row of one table, read from the database.
///
/// Records are values you read. Change the database through `Store`, which keeps its rules,
/// such as one draft review per stack and edits that keep the old text.
/// Times are stored as integer milliseconds since 1970, UTC.
public protocol StoreRecord: Codable, FetchableRecord, TableRecord, Hashable, Sendable {}

extension StoreRecord {
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .millisecondsSince1970
    }
}

/// `store_info`: keys `install_id` and `created_by_version`.
public struct StoreInfoRecord: StoreRecord {
    public static let databaseTableName = "store_info"

    public var key: String
    public var value: String
}

/// `repo`: one clone, matched by its git common directory.
public struct RepoRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "repo"

    public var id: Int
    public var commonDir: String
    /// Sorted `git rev-list --max-parents=0 HEAD`, one SHA per line.
    public var rootCommits: String
    public var remoteKey: String?
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case commonDir = "common_dir"
        case rootCommits = "root_commits"
        case remoteKey = "remote_key"
        case createdAt = "created_at"
    }
}

/// `agent_session`: one coding-agent session, keyed by `CLAUDE_CODE_SESSION_ID`.
public struct AgentSessionRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "agent_session"

    public var id: Int
    public var agent: AgentKind
    public var sessionKey: String
    public var pid: Int?
    /// The start time of `pid`, so a reused process ID never looks alive.
    public var pidStart: Int?
    public var cwd: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, agent, pid, cwd
        case sessionKey = "session_key"
        case pidStart = "pid_start"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case endedAt = "ended_at"
    }
}

/// `stack`: shown as `s<id>`.
public struct StackRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "stack"

    public var id: Int
    public var repoID: Int
    public var name: String
    public var source: StackSource
    public var trunkBranch: String
    public var ghStackID: String?
    public var ghStackNumber: Int?
    /// The agent session that gets this stack's wake-ups.
    public var driverSession: Int?
    public var state: StackState
    public var createdAt: Date
    public var endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, source, state
        case repoID = "repo_id"
        case trunkBranch = "trunk_branch"
        case ghStackID = "gh_stack_id"
        case ghStackNumber = "gh_stack_number"
        case driverSession = "driver_session"
        case createdAt = "created_at"
        case endedAt = "ended_at"
    }
}

/// `layer`: one branch of a stack. Position 1 is the bottom.
public struct LayerRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "layer"

    public var id: Int
    public var stackID: Int
    public var branch: String
    public var position: Int
    public var prNumber: Int?
    public var prURL: String?
    public var state: LayerState
    public var foldedInto: Int?
    public var createdAt: Date
    public var endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, branch, position, state
        case stackID = "stack_id"
        case prNumber = "pr_number"
        case prURL = "pr_url"
        case foldedInto = "folded_into"
        case createdAt = "created_at"
        case endedAt = "ended_at"
    }
}

/// `layer_name`: every branch name a layer has had.
public struct LayerNameRecord: StoreRecord {
    public static let databaseTableName = "layer_name"

    public var layerID: Int
    public var branch: String
    public var firstSeen: Date

    enum CodingKeys: String, CodingKey {
        case branch
        case layerID = "layer_id"
        case firstSeen = "first_seen"
    }
}

/// `snapshot`: one layer's fixed (base, head) pair.
public struct SnapshotRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "snapshot"

    public var id: Int
    public var layerID: Int
    public var baseSHA: String
    public var headSHA: String
    public var baseTree: String
    public var headTree: String
    public var baseRule: BaseRule
    public var parentRef: String
    /// `git patch-id --stable` of base..head.
    public var patchID: String?
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case layerID = "layer_id"
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case baseTree = "base_tree"
        case headTree = "head_tree"
        case baseRule = "base_rule"
        case parentRef = "parent_ref"
        case patchID = "patch_id"
        case createdAt = "created_at"
    }
}

/// `snapshot_file`: one changed file in a snapshot.
public struct SnapshotFileRecord: StoreRecord {
    public static let databaseTableName = "snapshot_file"

    public var snapshotID: Int
    public var path: String
    public var oldPath: String?
    public var change: FileChangeKind
    public var baseBlob: String?
    public var headBlob: String?
    /// A hash of this file's diff without line numbers.
    public var filePatch: String?
    /// Nil for a binary file.
    public var additions: Int?
    public var deletions: Int?

    enum CodingKeys: String, CodingKey {
        case path, change, additions, deletions
        case snapshotID = "snapshot_id"
        case oldPath = "old_path"
        case baseBlob = "base_blob"
        case headBlob = "head_blob"
        case filePatch = "file_patch"
    }
}

/// `revision`: one snapshot for every layer of a stack, shown as `r<number>`.
public struct RevisionRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "revision"

    public var id: Int
    public var stackID: Int
    public var number: Int
    public var trigger: RevisionTrigger
    /// A hash of the sorted (layer, base, head) triples. The same hash means no new revision.
    public var contentHash: String
    public var agentSession: Int?
    public var agentNote: String?
    public var dirtyFiles: Int
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, number, trigger
        case stackID = "stack_id"
        case contentHash = "content_hash"
        case agentSession = "agent_session"
        case agentNote = "agent_note"
        case dirtyFiles = "dirty_files"
        case createdAt = "created_at"
    }
}

/// `revision_layer`: which snapshot each layer had in a revision.
public struct RevisionLayerRecord: StoreRecord {
    public static let databaseTableName = "revision_layer"

    public var revisionID: Int
    public var layerID: Int
    public var position: Int
    public var snapshotID: Int

    enum CodingKeys: String, CodingKey {
        case position
        case revisionID = "revision_id"
        case layerID = "layer_id"
        case snapshotID = "snapshot_id"
    }
}

/// `review`: your batch of comments with a verdict, shown as `review <id>`.
public struct ReviewRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "review"

    public var id: Int
    public var stackID: Int
    /// The revision you were looking at. Set on submit.
    public var revisionID: Int?
    public var status: ReviewStatus
    public var verdict: ReviewVerdict?
    /// The summary you write in the Submit sheet.
    public var body: String
    public var deliveredTo: Int?
    public var createdAt: Date
    public var submittedAt: Date?
    public var deliveredAt: Date?
    public var repliedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status, verdict, body
        case stackID = "stack_id"
        case revisionID = "revision_id"
        case deliveredTo = "delivered_to"
        case createdAt = "created_at"
        case submittedAt = "submitted_at"
        case deliveredAt = "delivered_at"
        case repliedAt = "replied_at"
    }
}

/// `thread`: a conversation on a line range, a file or a whole layer, shown as `t<id>`.
public struct ThreadRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "thread"

    public var id: Int
    public var stackID: Int
    /// The thread's home layer.
    public var layerID: Int
    public var subject: ThreadSubject
    public var side: DiffSide?
    public var openedBy: Participant
    public var status: ThreadStatus
    /// When you last resolved it. Kept when you reopen the thread.
    public var resolvedAt: Date?
    public var resolvedRevisionID: Int?
    public var deletedAt: Date?
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, subject, side, status
        case stackID = "stack_id"
        case layerID = "layer_id"
        case openedBy = "opened_by"
        case resolvedAt = "resolved_at"
        case resolvedRevisionID = "resolved_revision_id"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
    }
}

/// `anchor`: where a thread sits in one revision, plus the text it covers. Only ever added.
public struct AnchorRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "anchor"

    public var id: Int
    public var threadID: Int
    public var revisionID: Int
    public var snapshotID: Int
    public var layerID: Int
    /// Nil when the file is gone or the thread is on the whole layer.
    public var path: String?
    public var blob: String?
    /// 1-based and inclusive. Nil for a file or layer thread, or when outdated.
    public var startLine: Int?
    public var endLine: Int?
    /// Outdated anchors only: "was near line N". A hint, never a place to port from.
    public var nearLine: Int?
    public var state: AnchorState
    public var method: AnchorMethod
    public var confidence: Double
    public var verified: Bool
    public var inDiff: Bool
    public var coveredText: String?
    /// Up to 3 lines.
    public var contextBefore: String?
    public var contextAfter: String?
    public var diffHunk: String?
    public var portedFrom: Int?
    public var engineVersion: Int
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, path, blob, state, method, confidence, verified
        case threadID = "thread_id"
        case revisionID = "revision_id"
        case snapshotID = "snapshot_id"
        case layerID = "layer_id"
        case startLine = "start_line"
        case endLine = "end_line"
        case nearLine = "near_line"
        case inDiff = "in_diff"
        case coveredText = "covered_text"
        case contextBefore = "context_before"
        case contextAfter = "context_after"
        case diffHunk = "diff_hunk"
        case portedFrom = "ported_from"
        case engineVersion = "engine_version"
        case createdAt = "created_at"
    }
}

/// `comment`: one message in a thread, shown as `c<id>`.
public struct CommentRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "comment"

    public var id: Int
    public var threadID: Int
    public var author: Participant
    public var agentSession: Int?
    /// Your comment's review. Nil for Send now and for agent replies.
    public var reviewID: Int?
    /// Set on agent comments only.
    public var replyStatus: AgentReplyStatus?
    public var body: String
    public var atRanges: [AtRange]?
    /// The stack's newest revision when the comment was written.
    public var revisionID: Int
    /// The first revision after an `addressed` reply.
    public var fixedIn: Int?
    /// Nil while the comment waits in a draft review.
    public var sentAt: Date?
    /// When `eyeballs inbox` first showed it. Only stops repeat wake-ups.
    public var deliveredAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, author, body
        case threadID = "thread_id"
        case agentSession = "agent_session"
        case reviewID = "review_id"
        case replyStatus = "reply_status"
        case atRanges = "at_ranges"
        case revisionID = "revision_id"
        case fixedIn = "fixed_in"
        case sentAt = "sent_at"
        case deliveredAt = "delivered_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

/// `comment_edit`: the text a comment had before an edit.
public struct CommentEditRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "comment_edit"

    public var id: Int
    public var commentID: Int
    public var oldBody: String
    public var replacedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case commentID = "comment_id"
        case oldBody = "old_body"
        case replacedAt = "replaced_at"
    }
}

/// `stop_block`: the Stop hook blocked this session once for this reason.
public struct StopBlockRecord: StoreRecord {
    public static let databaseTableName = "stop_block"

    public var sessionID: Int
    /// For example `undelivered:7`, `unreplied:7` or `unreplied:c215`.
    public var reasonKey: String
    public var blockedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case reasonKey = "reason_key"
        case blockedAt = "blocked_at"
    }
}

/// `pin`: a ref under `refs/eyeballs/<install-id>/` that keeps a reviewed commit alive.
public struct PinRecord: StoreRecord {
    public static let databaseTableName = "pin"

    public var repoID: Int
    public var sha: String
    public var createdAt: Date
    /// Set when retention lets the pin go and the ref is deleted.
    public var releasedAt: Date?

    enum CodingKeys: String, CodingKey {
        case sha
        case repoID = "repo_id"
        case createdAt = "created_at"
        case releasedAt = "released_at"
    }
}
