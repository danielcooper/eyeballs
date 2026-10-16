import Darwin
import EyeballsKit
import Foundation

/// Proof that this process is the only copy of Eyeballs using its home folder.
///
/// Take it at launch, before you open the store or the socket, and keep it for the life of the
/// process. It is an exclusive `flock` on `run/app.lock`, so the system releases it when the
/// process exits, even after a crash. Dropping the last reference releases it too.
public final class InstanceLock: Sendable {
    public let path: URL
    private let descriptor: Int32

    /// Takes the lock, or throws `InstanceLockError.alreadyRunning` naming the copy that holds it.
    ///
    /// - Parameter owner: what to tell a second copy, normally this app's bundle path.
    public static func acquire(in home: EyeballsHome, owner: String = Bundle.main.bundlePath) throws -> InstanceLock {
        try home.prepare()
        let path = home.lock
        let descriptor = Darwin.open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw InstanceLockError.cannotOpen(path: path.path, code: errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let holder = readOwner(descriptor)
            Darwin.close(descriptor)
            if code == EWOULDBLOCK {
                throw InstanceLockError.alreadyRunning(otherCopy: holder)
            }
            throw InstanceLockError.cannotOpen(path: path.path, code: code)
        }
        writeOwner(owner, to: descriptor)
        return InstanceLock(path: path, descriptor: descriptor)
    }

    private init(path: URL, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }

    private static func writeOwner(_ owner: String, to descriptor: Int32) {
        let bytes = Array((owner + "\n").utf8)
        _ = ftruncate(descriptor, 0)
        _ = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }

    private static func readOwner(_ descriptor: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let printable = firstLine.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let owner = String(printable).trimmingCharacters(in: .whitespaces)
        return owner.isEmpty ? nil : owner
    }
}

public enum InstanceLockError: Error, Equatable, LocalizedError {
    /// Another copy of Eyeballs holds the lock. `otherCopy` is its bundle path, when it wrote one.
    case alreadyRunning(otherCopy: String?)
    /// The lock file could not be opened or locked. `code` is the `errno` value.
    case cannotOpen(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning(let otherCopy?):
            "Eyeballs is already running from \(otherCopy). Quit that copy, then open this one again."
        case .alreadyRunning(nil):
            "Another copy of Eyeballs is already running. Quit it, then open this one again."
        case .cannotOpen(let path, let code):
            "Eyeballs could not lock \(path): \(String(cString: strerror(code)))."
        }
    }
}
