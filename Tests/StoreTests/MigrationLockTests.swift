@testable import EyeballsStore
import Foundation
import Testing

/// Fails when a shipped migration changes. Databases out in the world already ran it, so a
/// change would never reach them. Add a new migration instead.
struct MigrationLockTests {
    static let lockFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Store/Migrations.lock")

    /// The lock file's lines, as migration identifier to hash.
    static func lockedHashes() throws -> [String: String] {
        let text = try String(contentsOf: lockFile, encoding: .utf8)
        var hashes: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ")
            if fields.count == 2 { hashes[String(fields[0])] = String(fields[1]) }
        }
        return hashes
    }

    @Test func everyShippedMigrationMatchesItsLockedHash() throws {
        let locked = try Self.lockedHashes()
        for migration in StoreMigrations.shipped {
            let hash = try #require(locked[migration.identifier], """
                Migration \(migration.identifier) has no line in Store/Migrations.lock. Add: \(migration.identifier) \(migration.hash)
                """)
            #expect(hash == migration.hash, """
                Migration \(migration.identifier) changed after it shipped. Put it back, and add a new migration instead.
                """)
        }
    }

    @Test func theLockListsNoMigrationThatIsMissing() throws {
        let shipped = Set(StoreMigrations.shipped.map(\.identifier))
        #expect(Set(try Self.lockedHashes().keys).subtracting(shipped).isEmpty, "Store/Migrations.lock names a migration that no longer ships.")
    }

    @Test func changingTheSQLChangesTheHash() {
        let shipped = StoreMigrations.shipped[0]
        let edited = StoreMigrations.Migration(identifier: shipped.identifier, sql: shipped.sql + "\nCREATE TABLE extra (id INTEGER) STRICT;")
        #expect(edited.hash != shipped.hash)
    }
}
