@testable import EyeballsStore
import EyeballsKit
import Foundation
import GRDB
import Testing

struct BackupTests {
    @Test func openingTakesOneDailyBackupThatIsACompleteDatabase() throws {
        let clock = TestClock()
        try withTemporaryHome { home in
            let store = try Store.open(home: home, appVersion: "0.1.0", clock: clock.function)
            try addRepo(to: store)
            #expect(try store.backUpIfDue() == nil)
            try store.close()
            _ = try Store.open(home: home, appVersion: "0.1.0", clock: clock.function)

            let dailies = try StoreBackups(folder: home.backups).dailyBackups()
            #expect(dailies.map(\.lastPathComponent) == ["daily-2026-10-16.sqlite"])
            let attributes = try FileManager.default.attributesOfItem(atPath: dailies[0].path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600)

            let backup = try DatabaseQueue(path: dailies[0].path, configuration: { var c = Configuration(); c.readonly = true; return c }())
            let installID = try backup.read { try String.fetchOne($0, sql: "SELECT value FROM store_info WHERE key = 'install_id'") }
            #expect(installID == store.installID)
            #expect(try backup.read { try String.fetchOne($0, sql: "PRAGMA quick_check") } == "ok")
        }
    }

    @Test func theNewest14DailyBackupsAreKept() throws {
        let clock = TestClock()
        try withTemporaryHome { home in
            let store = try Store.open(home: home, appVersion: "0.1.0", clock: clock.function)
            for _ in 1...15 {
                clock.advance(days: 1)
                #expect(try store.backUpIfDue() != nil)
            }
            let names = try StoreBackups(folder: home.backups).dailyBackups().map(\.lastPathComponent)
            #expect(names.count == 14)
            #expect(names.first == "daily-2026-10-18.sqlite")
            #expect(names.last == "daily-2026-10-31.sqlite")
        }
    }

    @Test func aMigrationOfExistingDataIsBackedUpFirst() throws {
        let clock = TestClock()
        let withExtraMigration = StoreMigrations.shipped + [
            StoreMigrations.Migration(identifier: "v2-test", sql: "CREATE TABLE extra (id INTEGER PRIMARY KEY) STRICT;"),
        ]
        try withTemporaryHome { home in
            let first = try Store.open(home: home, appVersion: "0.1.0", clock: clock.function)
            try addRepo(to: first)
            try first.close()
            #expect(try preMigrationBackups(in: home).isEmpty)

            clock.advance(seconds: 60)
            let second = try Store.open(home: home, appVersion: "0.2.0", clock: clock.function, migrations: withExtraMigration)
            let backups = try preMigrationBackups(in: home)
            #expect(backups.map(\.lastPathComponent) == ["before-v2-test-20261016T120100.000Z.sqlite"])

            let before = try DatabaseQueue(path: backups[0].path)
            #expect(try before.read { try $0.tableExists("extra") } == false)
            #expect(try before.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo") } == 1)
            #expect(try second.reader.read { try $0.tableExists("extra") })
        }
    }

    private func addRepo(to store: Store) throws {
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO repo (common_dir, root_commits, created_at) VALUES ('/tmp/shop/.git', 'root1', 0)")
        }
    }

    private func preMigrationBackups(in home: EyeballsHome) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: home.backups, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("before-") }
    }
}
