import Foundation
import GRDB

extension Store {
    /// Finds the repo by its git common directory, or creates it.
    ///
    /// When no repo has this common directory, a repo with the same root commits and remote is
    /// the same clone moved to a new folder, so its `common_dir` is updated instead.
    public func upsertRepo(commonDir: String, rootCommits: String, remoteKey: String?) throws -> RepoRecord {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            if let repo = try RepoRecord.filter(sql: "common_dir = ?", arguments: [commonDir]).fetchOne(db) {
                return try update(RepoRecord.self, db, id: repo.id, set: "root_commits = ?, remote_key = COALESCE(?, remote_key)",
                                  arguments: [rootCommits, remoteKey])
            }
            if let remoteKey,
               let moved = try RepoRecord.filter(sql: "root_commits = ? AND remote_key = ?", arguments: [rootCommits, remoteKey]).fetchOne(db) {
                return try update(RepoRecord.self, db, id: moved.id, set: "common_dir = ?", arguments: [commonDir])
            }
            return try insert(RepoRecord.self, db, sql: """
                INSERT INTO repo (common_dir, root_commits, remote_key, created_at) VALUES (?, ?, ?, ?)
                """, arguments: [commonDir, rootCommits, remoteKey, now])
        }
    }

    /// Registers an agent session on its first call, and refreshes it on every later one.
    ///
    /// A later call updates `last_seen`, `pid` and `pid_start`, and clears `ended_at`, so a
    /// resumed session is live again.
    public func upsertAgentSession(agent: AgentKind, sessionKey: String, pid: Int?, pidStart: Int?, cwd: String) throws -> AgentSessionRecord {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            try insert(AgentSessionRecord.self, db, sql: """
                INSERT INTO agent_session (agent, session_key, pid, pid_start, cwd, first_seen, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (agent, session_key) DO UPDATE SET
                  pid = excluded.pid, pid_start = excluded.pid_start, last_seen = excluded.last_seen, ended_at = NULL
                """, arguments: [agent, sessionKey, pid, pidStart, cwd, now, now])
        }
    }

    /// Marks a session ended, for the SessionEnd hook. It keeps any driver role it had.
    public func endAgentSession(id: Int) throws {
        let now = clock().databaseMilliseconds
        try pool.write { db in
            try db.execute(sql: "UPDATE agent_session SET ended_at = ? WHERE id = ?", arguments: [now, id])
        }
    }
}

// MARK: Helpers shared by the Store+… files

/// Runs an `INSERT` and returns the new row.
func insert<Record: StoreRecord>(_ type: Record.Type, _ db: Database, sql: String, arguments: StatementArguments) throws -> Record {
    // INSERT … RETURNING always yields the row it wrote, so this never unwraps nil.
    try Record.fetchOne(db, sql: sql + " RETURNING *", arguments: arguments)!
}

/// Runs `UPDATE <table> SET <set> WHERE id = <id>` and returns the changed row.
func update<Record: StoreRecord & Identifiable>(
    _ type: Record.Type, _ db: Database, id: Int, set assignments: String, arguments: StatementArguments
) throws -> Record where Record.ID == Int {
    let sql = "UPDATE \(Record.databaseTableName) SET \(assignments) WHERE id = ? RETURNING *"
    guard let record = try Record.fetchOne(db, sql: sql, arguments: arguments + [id]) else {
        throw StoreError.notFound(table: Record.databaseTableName, id: id)
    }
    return record
}

/// Fetches a row by ID, or throws `StoreError.notFound`.
func existing<Record: StoreRecord & Identifiable>(_ type: Record.Type, _ db: Database, id: Int) throws -> Record where Record.ID == Int {
    guard let record = try Record.fetchOne(db, id: id) else {
        throw StoreError.notFound(table: Record.databaseTableName, id: id)
    }
    return record
}
