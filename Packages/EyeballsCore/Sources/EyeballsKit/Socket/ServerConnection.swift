import Darwin
import Foundation

/// One accepted connection. It reads one request line, then either writes one response and
/// closes, or stays open as a stream.
///
/// Everything here runs on the server's queue.
final class ServerConnection {
    struct Stream {
        var request: StreamRequest
        var requestID: Int
        var client: ClientIdentity
        var openedAt: Date
    }

    enum Phase {
        case readingRequest
        case handling
        case streaming(Stream)
        case closing
        case closed
    }

    let id: Int
    let peer: Peer
    var phase = Phase.readingRequest
    /// True once the client has closed its side. A stream then has no way to notice it leave,
    /// so it is not opened.
    private(set) var peerStoppedSending = false
    private(set) var wasStreaming = false

    var onRequestLine: ((ServerConnection, [UInt8]) -> Void)?
    var onRequestTooLarge: ((ServerConnection) -> Void)?
    var onClose: ((ServerConnection) -> Void)?

    init(id: Int, fd: Int32, peer: Peer, queue: DispatchQueue, maximumRequestBytes: Int) {
        self.id = id
        self.fd = fd
        self.peer = peer
        self.queue = queue
        self.maximumRequestBytes = maximumRequestBytes
        closer = DescriptorCloser(fd: fd)
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    }

    func start(requestTimeout: Duration) {
        let closer = closer
        closer.addSource()
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        readSource.setCancelHandler { closer.sourceCancelled() }
        readSource.resume()
        schedule(after: requestTimeout) { [weak self] in
            guard let self, case .readingRequest = self.phase else { return }
            self.close()
        }
    }

    /// Writes `response` and closes once it has gone out.
    func finish(with response: Response) {
        guard isOpen else { return }
        cancelTimer()
        if case .streaming = phase { wasStreaming = true }
        phase = .closing
        closeWhenFlushed = true
        send(response.line())
    }

    func send(_ data: Data) {
        if case .closed = phase { return }
        output.append(contentsOf: data)
        flush()
    }

    func schedule(after delay: Duration, _ action: @escaping () -> Void) {
        cancelTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(delay.wholeMilliseconds)))
        timer.setEventHandler(handler: action)
        timer.resume()
        self.timer = timer
    }

    func close() {
        if case .closed = phase { return }
        if case .streaming = phase { wasStreaming = true }
        phase = .closed
        cancelTimer()
        readSource.cancel()
        if let writeSource {
            if !writeSourceRunning { writeSource.resume() }
            writeSource.cancel()
        }
        onClose?(self)
        onRequestLine = nil
        onRequestTooLarge = nil
        onClose = nil
    }

    var isOpen: Bool {
        switch phase {
        case .readingRequest, .handling, .streaming: true
        case .closing, .closed: false
        }
    }

    private let fd: Int32
    private let queue: DispatchQueue
    private let maximumRequestBytes: Int
    private let readSource: any DispatchSourceRead
    private var writeSource: (any DispatchSourceWrite)?
    private var writeSourceRunning = false
    private let closer: DescriptorCloser
    private var timer: (any DispatchSourceTimer)?
    private var input: [UInt8] = []
    private var output: [UInt8] = []
    private var closeWhenFlushed = false

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                received(chunk[..<count])
                if case .closed = phase { return }
                continue
            }
            if count == 0 {
                endOfInput()
                return
            }
            switch errno {
            case EINTR: continue
            case EAGAIN: return
            default:
                close()
                return
            }
        }
    }

    private func received(_ bytes: ArraySlice<UInt8>) {
        guard case .readingRequest = phase else { return }
        let alreadySearched = input.count
        input.append(contentsOf: bytes)
        if let newline = input[alreadySearched...].firstIndex(of: UInt8(ascii: "\n")) {
            takeRequestLine(Array(input[..<newline]))
        } else if input.count > maximumRequestBytes {
            input = []
            phase = .handling
            onRequestTooLarge?(self)
        }
    }

    /// The client closed its side. A request sent without a final newline still counts.
    private func endOfInput() {
        peerStoppedSending = true
        readSource.cancel()
        switch phase {
        case .readingRequest:
            if input.isEmpty || input.count > maximumRequestBytes {
                close()
            } else {
                takeRequestLine(input)
            }
        case .streaming:
            close()
        case .handling, .closing, .closed:
            break
        }
    }

    private func takeRequestLine(_ line: [UInt8]) {
        input = []
        phase = .handling
        cancelTimer()
        onRequestLine?(self, line)
    }

    private func flush() {
        if case .closed = phase { return }
        while !output.isEmpty {
            let written = output.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                output.removeFirst(written)
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN {
                startWriteSource()
                return
            }
            close()
            return
        }
        stopWriteSource()
        if closeWhenFlushed { close() }
    }

    private func startWriteSource() {
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            let closer = closer
            closer.addSource()
            source.setEventHandler { [weak self] in self?.flush() }
            source.setCancelHandler { closer.sourceCancelled() }
            writeSource = source
            writeSourceRunning = false
        }
        if !writeSourceRunning {
            writeSource?.resume()
            writeSourceRunning = true
        }
    }

    private func stopWriteSource() {
        guard let writeSource, writeSourceRunning else { return }
        writeSource.suspend()
        writeSourceRunning = false
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}

/// Closes a descriptor once every dispatch source on it has finished cancelling, as Dispatch
/// requires. It outlives the connection, because a cancel handler can run after the server has
/// let the connection go. Its count changes only on the server's queue.
private final class DescriptorCloser: @unchecked Sendable {
    private let fd: Int32
    private var openSources = 0

    init(fd: Int32) {
        self.fd = fd
    }

    func addSource() {
        openSources += 1
    }

    func sourceCancelled() {
        openSources -= 1
        if openSources == 0 { close(fd) }
    }
}
