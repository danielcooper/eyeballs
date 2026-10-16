@testable import EyeballsStore
import EyeballsKit
import Foundation
import GRDB
import Synchronization

/// A clock that only moves when a test moves it.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    /// 2026-10-16 12:00:00 UTC.
    init(_ start: Date = Date(timeIntervalSince1970: 1_792_152_000)) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(seconds: TimeInterval) {
        current.withLock { $0 += seconds }
    }

    func advance(days: Int) {
        advance(seconds: TimeInterval(days) * 86_400)
    }

    var function: @Sendable () -> Date { { self.now } }
}

/// Runs `body` with an Eyeballs home in a new folder under `/tmp`, then deletes the folder.
///
/// The home comes from `EYEBALLS_HOME`, as the app reads it, but through the `environment`
/// argument, so parallel tests never change the process environment.
func withTemporaryHome<T>(_ body: (EyeballsHome) throws -> T) throws -> T {
    let folder = "/tmp/eb-store-\(UInt32.random(in: .min ... .max))"
    let home = EyeballsHome.current(debug: true, environment: ["EYEBALLS_HOME": folder])
    defer { try? FileManager.default.removeItem(atPath: folder) }
    return try body(home)
}

extension Store {
    func fetchAll<Record: FetchableRecord & TableRecord>(_ type: Record.Type) throws -> [Record] {
        try reader.read { try Record.fetchAll($0) }
    }

    func comment(_ id: Int) throws -> CommentRecord {
        try reader.read { try CommentRecord.fetchOne($0, id: id)! }
    }

    func thread(_ id: Int) throws -> ThreadRecord {
        try reader.read { try ThreadRecord.fetchOne($0, id: id)! }
    }

    func review(_ id: Int) throws -> ReviewRecord {
        try reader.read { try ReviewRecord.fetchOne($0, id: id)! }
    }
}
