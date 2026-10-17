import Foundation
import GRDB

/// Copies of the database in `Backups/`, taken with `VACUUM INTO`.
///
/// - **Daily:** `daily-2026-10-16.sqlite`, by UTC date. The newest 14 are kept.
/// - **Before a migration:** `before-v2-20261016T140211.123Z.sqlite`. These are kept for good.
///
/// Each backup is a complete database on its own. The README says how to restore one.
struct StoreBackups {
    static let dailyKept = 14

    let folder: URL

    @discardableResult
    func takeDailyIfDue(of pool: DatabasePool, now: Date) throws -> URL? {
        let file = folder.appendingPathComponent("daily-\(Self.day(now)).sqlite")
        guard !FileManager.default.fileExists(atPath: file.path) else { return nil }
        try copy(pool, to: file)
        try pruneDaily()
        return file
    }

    @discardableResult
    func takeBeforeMigration(_ migration: String, of pool: DatabasePool, now: Date) throws -> URL {
        let file = folder.appendingPathComponent("before-\(migration)-\(Self.moment(now)).sqlite")
        try copy(pool, to: file)
        return file
    }

    /// The daily backups, oldest first.
    func dailyBackups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("daily-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func copy(_ pool: DatabasePool, to file: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [file.path])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func pruneDaily() throws {
        for old in try dailyBackups().dropLast(Self.dailyKept) {
            try FileManager.default.removeItem(at: old)
        }
    }

    private static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }

    private static func moment(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted, includingFractionalSeconds: true, timeZone: .gmt))
    }
}
