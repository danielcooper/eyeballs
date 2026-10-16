import Foundation
import GRDB

extension Store {
    /// The ref that pins a commit: `refs/eyeballs/<installID>/<sha>`.
    public func pinRef(sha: String) -> String {
        "refs/eyeballs/\(installID)/\(sha)"
    }

    /// Records pins after their refs are written. Write the refs first, so a row never names a
    /// missing ref. Pinning a released commit again makes it live again.
    public func recordPins(repoID: Int, shas: [String]) throws {
        let now = clock().databaseMilliseconds
        try pool.write { db in
            for sha in shas {
                try db.execute(sql: """
                    INSERT INTO pin (repo_id, sha, created_at) VALUES (?, ?, ?)
                    ON CONFLICT (repo_id, sha) DO UPDATE SET released_at = NULL
                    """, arguments: [repoID, sha, now])
            }
        }
    }

    /// Marks pins released, once retention lets them go and their refs are deleted.
    public func releasePins(repoID: Int, shas: [String]) throws {
        let now = clock().databaseMilliseconds
        try pool.write { db in
            for sha in shas {
                try db.execute(sql: "UPDATE pin SET released_at = ? WHERE repo_id = ? AND sha = ? AND released_at IS NULL",
                               arguments: [now, repoID, sha])
            }
        }
    }

    /// The repo's pins that have not been released, oldest first.
    public func livePins(repoID: Int) throws -> [PinRecord] {
        try pool.read { db in
            try PinRecord.filter(sql: "repo_id = ? AND released_at IS NULL", arguments: [repoID]).order(sql: "created_at, sha").fetchAll(db)
        }
    }
}
