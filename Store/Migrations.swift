import CryptoKit
import Foundation
import GRDB

/// The schema migrations that have shipped, oldest first.
///
/// Migrations only ever add tables, columns and indexes. To change the schema, append a new
/// migration to `shipped` and add its hash to `Store/Migrations.lock`. Never edit one that has
/// shipped, because databases out in the world already ran it.
enum StoreMigrations {
    struct Migration: Sendable {
        let identifier: String
        let sql: String

        /// The SHA-256 of the migration's SQL, as `Migrations.lock` records it.
        var hash: String {
            SHA256.hash(data: Data(sql.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    static let shipped: [Migration] = [
        Migration(identifier: "v1", sql: schemaVersion1),
    ]

    static func migrator(for migrations: [Migration] = shipped) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for migration in migrations {
            migrator.registerMigration(migration.identifier) { db in
                try db.execute(sql: migration.sql)
            }
        }
        return migrator
    }
}
