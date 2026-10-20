import EyeballsKit
import Foundation
import GRDB

/// Eyeballs' database: every stack, revision, review, thread and comment.
///
/// Only the app opens it, and only after it holds the `InstanceLock`. Read with `reader`, for
/// example to observe a stack with `ValueObservation`, and change it only through the methods
/// in the `Store+…` files, which keep its rules. Every method runs in one transaction
/// and blocks until it finishes.
public final class Store: Sendable {
    public let home: EyeballsHome
    /// This store's ID, used in pin names: `refs/eyeballs/<installID>/<sha>`.
    public let installID: String
    let pool: DatabasePool
    let clock: @Sendable () -> Date

    /// Read access to the database, for fetches and `ValueObservation`.
    public var reader: any DatabaseReader { pool }

    /// Opens the store in `home`, creating it if needed.
    ///
    /// In order, this checks the SQLite version, runs `PRAGMA quick_check`, backs up the
    /// database before any migration, migrates it, then takes the daily backup if it is due.
    /// A damaged file throws `StoreError.damagedDatabase` and is left as it is.
    ///
    /// - Parameters:
    ///   - appVersion: written to `store_info` when the database is first created.
    ///   - clock: the current time. Tests pass a fixed clock.
    public static func open(
        home: EyeballsHome,
        appVersion: String,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Store {
        try open(home: home, appVersion: appVersion, clock: clock, migrations: StoreMigrations.shipped)
    }

    /// Closes every connection. Later calls on this store throw.
    public func close() throws {
        try pool.close()
    }

    /// Takes the daily backup unless today's already exists, and keeps the newest 14.
    ///
    /// `open` calls this. Call it again from a timer when the app runs for days.
    /// - Returns: the new backup file, or nil when today's already existed.
    @discardableResult
    public func backUpIfDue() throws -> URL? {
        try StoreBackups(folder: home.backups).takeDailyIfDue(of: pool, now: clock())
    }

    static func open(
        home: EyeballsHome,
        appVersion: String,
        clock: @escaping @Sendable () -> Date,
        migrations: [StoreMigrations.Migration]
    ) throws -> Store {
        try home.prepare()
        try createDatabaseFile(at: home.database)
        let pool = try openCheckedPool(home)

        let backups = StoreBackups(folder: home.backups)
        let migrator = StoreMigrations.migrator(for: migrations)
        let pending = try pool.read { db in
            let applied = try migrator.appliedIdentifiers(db)
            return applied.isEmpty ? [] : migrator.migrations.filter { !applied.contains($0) }
        }
        if let first = pending.first {
            try backups.takeBeforeMigration(first, of: pool, now: clock())
        }
        try migrator.migrate(pool)
        let installID = try pool.write { db in
            try recordStoreInfo(db, appVersion: appVersion)
        }
        try backups.takeDailyIfDue(of: pool, now: clock())
        return Store(home: home, installID: installID, pool: pool, clock: clock)
    }

    private init(home: EyeballsHome, installID: String, pool: DatabasePool, clock: @escaping @Sendable () -> Date) {
        self.home = home
        self.installID = installID
        self.pool = pool
        self.clock = clock
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.label = "Eyeballs store"
        configuration.foreignKeysEnabled = true
        return configuration
    }

    /// Opens the pool, then checks the SQLite version and the file's integrity.
    private static func openCheckedPool(_ home: EyeballsHome) throws -> DatabasePool {
        do {
            let pool = try DatabasePool(path: home.database.path, configuration: configuration())
            try pool.writeWithoutTransaction { db in
                // GRDB sets synchronous=NORMAL when it opens a WAL pool, and NORMAL can lose the last commits on power loss.
                try db.execute(sql: "PRAGMA synchronous = FULL")
                try checkSQLiteVersion(db)
                try checkIntegrity(db, backups: home.backups)
            }
            return pool
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            throw StoreError.damagedDatabase(backups: home.backups.path)
        }
    }

    /// Creates an empty database readable only by you. SQLite gives the WAL files the same mode.
    private static func createDatabaseFile(at url: URL) throws {
        let files = FileManager.default
        if !files.fileExists(atPath: url.path) {
            files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func checkSQLiteVersion(_ db: Database) throws {
        let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "0"
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let padded = parts + Array(repeating: 0, count: max(0, 3 - parts.count))
        if padded.lexicographicallyPrecedes([3, 37, 0]) {
            throw StoreError.sqliteTooOld(found: version)
        }
    }

    private static func checkIntegrity(_ db: Database, backups: URL) throws {
        if try String.fetchAll(db, sql: "PRAGMA quick_check") != ["ok"] {
            throw StoreError.damagedDatabase(backups: backups.path)
        }
    }

    /// Writes `install_id` and `created_by_version` the first time, and returns the install ID.
    private static func recordStoreInfo(_ db: Database, appVersion: String) throws -> String {
        try db.execute(
            sql: "INSERT INTO store_info (key, value) VALUES ('install_id', ?), ('created_by_version', ?) ON CONFLICT (key) DO NOTHING",
            arguments: [newInstallID(), appVersion])
        return try String.fetchOne(db, sql: "SELECT value FROM store_info WHERE key = 'install_id'") ?? ""
    }

    private static func newInstallID() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

extension Date {
    /// The value the database stores for this time: milliseconds since 1970, UTC.
    var databaseMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
