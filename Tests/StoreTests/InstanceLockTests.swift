@testable import EyeballsStore
import EyeballsKit
import Foundation
import Testing

struct InstanceLockTests {
    @Test func aSecondLockNamesTheCopyThatHoldsTheFirst() throws {
        try withTemporaryHome { home in
            let first = try InstanceLock.acquire(in: home, owner: "/Applications/Eyeballs.app")
            #expect(first.path == home.lock)

            #expect(throws: InstanceLockError.alreadyRunning(otherCopy: "/Applications/Eyeballs.app")) {
                _ = try InstanceLock.acquire(in: home, owner: "/Users/alex/Downloads/Eyeballs.app")
            }
            let message = InstanceLockError.alreadyRunning(otherCopy: "/Applications/Eyeballs.app").localizedDescription
            #expect(message.hasPrefix("Eyeballs is already running from /Applications/Eyeballs.app"))
            withExtendedLifetime(first) {}
        }
    }

    @Test func theLockIsFreeOnceItsHolderLetsGo() throws {
        try withTemporaryHome { home in
            var first: InstanceLock? = try InstanceLock.acquire(in: home, owner: "first")
            #expect(first != nil)
            first = nil
            let second = try InstanceLock.acquire(in: home, owner: "second")
            let owner = try String(contentsOf: second.path, encoding: .utf8)
            #expect(owner == "second\n")
        }
    }

    @Test func theLockFileIsReadableOnlyByYou() throws {
        try withTemporaryHome { home in
            let lock = try InstanceLock.acquire(in: home, owner: "first")
            let attributes = try FileManager.default.attributesOfItem(atPath: lock.path.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600)
        }
    }

    @Test func controlCharactersInTheOwnerNeverReachTheMessage() throws {
        try withTemporaryHome { home in
            let first = try InstanceLock.acquire(in: home, owner: "/Apps/Eye\u{1b}[31mballs.app")
            #expect(throws: InstanceLockError.alreadyRunning(otherCopy: "/Apps/Eye[31mballs.app")) {
                _ = try InstanceLock.acquire(in: home, owner: "second")
            }
            withExtendedLifetime(first) {}
        }
    }
}
