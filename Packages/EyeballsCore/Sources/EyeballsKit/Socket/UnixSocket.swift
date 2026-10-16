import Darwin

/// Small wrappers around the BSD socket calls both ends use.
enum UnixSocket {
    /// `sun_path` holds 104 bytes, including the terminating zero.
    static let maximumPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// Throws `.pathTooLong` when `path` does not fit in `sun_path`.
    static func address(for path: String) throws(SocketPathError) -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumPathBytes else { throw SocketPathError(bytes: bytes.count) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// A new stream socket that is closed on exec and never raises SIGPIPE.
    static func makeStreamSocket() throws(SystemCallError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SystemCallError("socket") }
        do {
            try configure(fd)
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    /// Sets close-on-exec, no SIGPIPE and non-blocking mode.
    static func configure(_ fd: Int32) throws(SystemCallError) {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw SystemCallError("fcntl") }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SystemCallError("setsockopt")
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw SystemCallError("fcntl") }
    }

    static func connect(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func bind(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Waits until `fd` is ready for `events`. Returns false when the time runs out.
    /// A nil `deadline` waits forever.
    static func wait(_ fd: Int32, for events: Int16, until deadline: ContinuousClock.Instant?) throws(SystemCallError) -> Bool {
        while true {
            var timeout: Int32 = -1
            if let deadline {
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining <= .zero { return false }
                timeout = Int32(clamping: remaining.wholeMilliseconds + 1)
            }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, timeout)
            if result > 0 { return true }
            if result == 0 { if deadline == nil { continue } else { return false } }
            if errno != EINTR { throw SystemCallError("poll") }
        }
    }
}

/// A socket path that does not fit in `sun_path`.
struct SocketPathError: Error {
    var bytes: Int
}

/// A system call failed. It keeps `errno`, whose text names the cause.
public struct SystemCallError: Error, Sendable, Hashable, CustomStringConvertible {
    public var call: String
    public var code: Int32

    init(_ call: String, code: Int32 = errno) {
        self.call = call
        self.code = code
    }

    public var description: String { "\(call) failed: \(String(cString: strerror(code)))" }
}

extension Duration {
    var wholeMilliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    /// Whole seconds, rounded up, for messages such as "within 10 s".
    var wholeSecondsRoundedUp: Int64 {
        let (seconds, attoseconds) = components
        return attoseconds > 0 ? seconds + 1 : seconds
    }
}
