@testable import EyeballsStore
import EyeballsKit
import Foundation
import GRDB
import Testing

struct StoreOpeningTests {
    static let schemaVersion1Tables = [
        "store_info", "repo", "agent_session", "stack", "layer", "layer_name", "snapshot", "snapshot_file",
        "revision", "revision_layer", "review", "thread", "anchor", "comment", "comment_edit", "stop_block", "pin",
    ]
    static let schemaVersion1Indexes = [
        "layer_live_branch", "review_one_draft", "anchor_origin", "anchor_port_once", "anchor_by_thread", "comment_by_thread",
    ]

    @Test func migrationCreatesEveryTableAndIndexOfSchemaVersion1() throws {
        try withTemporaryHome { home in
            let store = try Store.open(home: home, appVersion: "0.1.0")
            try store.reader.read { db in
                let tables = try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                    """)
                #expect(Set(tables) == Set(Self.schemaVersion1Tables))
                let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
                #expect(Set(indexes) == Set(Self.schemaVersion1Indexes))
                let strict = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_list WHERE strict = 1")
                #expect(Set(strict) == Set(Self.schemaVersion1Tables))
                #expect(try StoreMigrations.migrator().appliedIdentifiers(db) == ["v1"])
            }
        }
    }

    @Test func writerUsesWALWithFullSyncAndForeignKeys() throws {
        try withTemporaryHome { home in
            let store = try Store.open(home: home, appVersion: "0.1.0")
            let (journalMode, synchronous, foreignKeys) = try store.pool.writeWithoutTransaction { db in
                (try String.fetchOne(db, sql: "PRAGMA journal_mode"),
                 try Int.fetchOne(db, sql: "PRAGMA synchronous"),
                 try Int.fetchOne(db, sql: "PRAGMA foreign_keys"))
            }
            #expect(journalMode == "wal")
            #expect(synchronous == 2)
            #expect(foreignKeys == 1)
            #expect(throws: DatabaseError.self) {
                try store.pool.write { db in
                    try db.execute(sql: "INSERT INTO stack (repo_id, name, source, trunk_branch, created_at) VALUES (999, 'x', 'gh_stack', 'main', 0)")
                }
            }
        }
    }

    @Test func databaseFileIsReadableOnlyByYou() throws {
        try withTemporaryHome { home in
            _ = try Store.open(home: home, appVersion: "0.1.0")
            let attributes = try FileManager.default.attributesOfItem(atPath: home.database.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600)
        }
    }

    @Test func installIDSurvivesReopening() throws {
        try withTemporaryHome { home in
            let first = try Store.open(home: home, appVersion: "0.1.0")
            let installID = first.installID
            try first.close()

            let second = try Store.open(home: home, appVersion: "0.2.0")
            #expect(second.installID == installID)
            #expect(installID.count == 12)
            let createdBy = try second.reader.read { try String.fetchOne($0, sql: "SELECT value FROM store_info WHERE key = 'created_by_version'") }
            #expect(createdBy == "0.1.0")
        }
    }

    @Test func aDamagedDatabaseFailsTheIntegrityCheck() throws {
        try withTemporaryHome { home in
            try home.prepare()
            let queue = try DatabaseQueue(path: home.database.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE filler (id INTEGER PRIMARY KEY, text TEXT)")
                for row in 0..<500 {
                    try db.execute(sql: "INSERT INTO filler (text) VALUES (?)", arguments: [String(repeating: "x", count: 200) + "\(row)"])
                }
            }
            try queue.close()
            let file = try FileHandle(forUpdating: home.database)
            try file.seek(toOffset: 2 * 4096)
            try file.write(contentsOf: Data(repeating: 0xFF, count: 16))
            try file.close()

            #expect(throws: StoreError.damagedDatabase(backups: home.backups.path)) {
                _ = try Store.open(home: home, appVersion: "0.1.0")
            }
        }
    }

    @Test func unknownEnumValuesDecodeAsUnknown() throws {
        try withTemporaryHome { home in
            let store = try Store.open(home: home, appVersion: "0.1.0")
            let stack = try store.pool.write { db in
                try db.execute(sql: "INSERT INTO repo (common_dir, root_commits, created_at) VALUES ('/tmp/shop/.git', 'root1', 0)")
                try db.execute(sql: """
                    INSERT INTO stack (repo_id, name, source, trunk_branch, state, created_at)
                    VALUES (?, 'checkout-v2', 'jj', 'main', 'paused', 0)
                    """, arguments: [db.lastInsertedRowID])
                return try StackRecord.fetchOne(db, id: Int(db.lastInsertedRowID))
            }
            #expect(stack?.state == .unknown("paused"))
            #expect(stack?.source == .unknown("jj"))
            #expect(StackState(rawValue: "paused").rawValue == "paused")
            #expect(StackState(rawValue: "merged") == .merged)
        }
    }
}
