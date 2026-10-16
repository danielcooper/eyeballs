/// Reads the two forms of `eyeballs reply` input: `## t41 addressed` text blocks, and the
/// `--json-file` array.
///
/// Both are all or nothing. Any problem fails the whole batch with a `bad_input` error that
/// lists every problem found, so the agent can fix them in one go.
public enum ReplyBatch {
    /// Reads text such as:
    ///
    /// ```text
    /// ## t42 addressed
    /// at: Sources/API/Client.swift:40-58
    /// Only 5xx and URLError.timedOut retry now.
    /// ```
    ///
    /// A block starts at a line beginning `## t` or `## ` and a digit, at column 0. `at:` lines
    /// directly under the header name where the fix is. To keep a line starting `## t` in a
    /// body, indent it.
    public static func parse(_ text: String) throws -> [ReplyItem] {
        var reader = BlockReader()
        // Split on scalars: as Characters, "\r\n" is one character and never equals "\n".
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(Substring.init)
        for (offset, rawLine) in lines.enumerated() {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            reader.read(line, number: offset + 1)
        }
        reader.finishBlock()
        return try reader.result()
    }

    /// Reads `[{"thread":"t42","status":"addressed","body":"…","at":["Sources/API/Client.swift:40-58"]}]`.
    /// `thread` may also be `"42"` or `42`, and `at` may be left out.
    public static func parseJSON(_ bytes: some Collection<UInt8>) throws -> [ReplyItem] {
        let value: JSONValue
        do {
            value = try JSONValue(parsing: bytes)
        } catch let error as JSONParseError {
            throw EyeballsError.badInput("The reply JSON does not parse: \(error.reason) at byte \(error.offset).", hint: jsonShapeHint)
        }
        guard case .array(let entries) = value else {
            throw EyeballsError.badInput("The reply JSON must be an array of replies.", hint: jsonShapeHint)
        }
        var problems: [String] = []
        var items: [ReplyItem] = []
        for (offset, entry) in entries.enumerated() {
            let label = "Reply \(offset + 1)"
            guard case .object(let object) = entry else {
                problems.append("\(label) is not an object")
                continue
            }
            let thread: ThreadID? = switch object["thread"] {
            case .string(let text): ThreadID(parsing: text)
            case .integer(let number) where number > 0: ThreadID(Int(number))
            default: nil
            }
            guard let thread else {
                problems.append("\(label) needs a thread such as \"t41\"")
                continue
            }
            guard let status = object["status"]?.stringValue.flatMap({ ReplyStatus(rawValue: $0.lowercased()) }) else {
                problems.append("\(label) needs a status of addressed, declined or question")
                continue
            }
            guard let body = object["body"]?.stringValue else {
                problems.append("\(label) needs a body string")
                continue
            }
            var spans: [LineSpan] = []
            switch object["at"] {
            case nil, .null?:
                break
            case .array(let ranges)?:
                for range in ranges {
                    guard let text = range.stringValue, let span = try? LineSpan(parsing: text) else {
                        problems.append("\(label) has an at entry that is not PATH:A-B")
                        continue
                    }
                    spans.append(span)
                }
            default:
                problems.append("\(label) needs at to be an array of PATH:A-B strings")
            }
            items.append(ReplyItem(thread: thread, status: status, body: body, at: spans))
        }
        try throwIfAny(problems)
        try ReplyArguments(replies: items).validate()
        return items
    }

    static let jsonShapeHint = #"Send [{"thread":"t41","status":"addressed","body":"…","at":["path:40-58"]}]."#

    static func throwIfAny(_ problems: [String]) throws {
        guard let first = problems.first else { return }
        let shown = problems.prefix(5)
        let more = problems.count > shown.count ? " (and \(problems.count - shown.count) more)" : ""
        let message = problems.count == 1
            ? "The reply batch has a problem: \(first). Nothing was sent."
            : "The reply batch has \(problems.count) problems: \(shown.joined(separator: "; "))\(more). Nothing was sent."
        throw EyeballsError.badInput(message, hint: "Fix the batch and run eyeballs reply again.")
    }
}

/// Collects blocks line by line, noting every problem rather than stopping at the first.
private struct BlockReader {
    private struct Block {
        var thread: ThreadID
        var status: ReplyStatus
        var headerLine: Int
        var at: [LineSpan] = []
        var body: [Substring] = []
        var readingAtLines = true
    }

    private var block: Block?
    private var items: [ReplyItem] = []
    private var problems: [String] = []
    private var sawHeader = false

    mutating func read(_ line: Substring, number: Int) {
        if Self.isHeader(line) {
            finishBlock()
            sawHeader = true
            block = parseHeader(line, number: number)
            return
        }
        guard sawHeader else {
            if !line.allSatisfy(\.isWhitespace) {
                problems.append("line \(number) comes before the first ## t<id> <status> header")
            }
            return
        }
        guard var current = block else { return }
        if current.readingAtLines, line.hasPrefix("at:") {
            do {
                current.at.append(try LineSpan(parsing: String(line.dropFirst(3)).trimmingWhitespace()))
            } catch {
                problems.append("line \(number) is an at: line that is not PATH:A-B")
            }
        } else {
            current.readingAtLines = false
            current.body.append(line)
        }
        block = current
    }

    mutating func finishBlock() {
        guard let current = block else { return }
        block = nil
        var body = current.body
        while let first = body.first, first.allSatisfy(\.isWhitespace) { body.removeFirst() }
        while let last = body.last, last.allSatisfy(\.isWhitespace) { body.removeLast() }
        guard !body.isEmpty else {
            problems.append("the block for \(current.thread) on line \(current.headerLine) has no reply text")
            return
        }
        items.append(ReplyItem(thread: current.thread, status: current.status, body: body.joined(separator: "\n"), at: current.at))
    }

    func result() throws -> [ReplyItem] {
        var problems = problems
        if !sawHeader {
            problems.append("it has no ## t<id> <status> header")
        }
        try ReplyBatch.throwIfAny(problems)
        try ReplyArguments(replies: items).validate()
        return items
    }

    /// A header starts `## t` or `## ` and a digit at column 0. Such a line is always read as a
    /// header, even a malformed one, so a typo never slips into the previous reply's body.
    private static func isHeader(_ line: Substring) -> Bool {
        guard line.hasPrefix("## ") else { return false }
        guard let next = line.dropFirst(3).first else { return false }
        return next == "t" || (next.isASCII && next.isNumber)
    }

    private mutating func parseHeader(_ line: Substring, number: Int) -> Block? {
        let words = line.dropFirst(3).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard words.count == 2 else {
            problems.append("line \(number) must be a header such as ## t41 addressed, or be indented to stay in the body")
            return nil
        }
        guard let thread = ThreadID(parsing: String(words[0])) else {
            problems.append("line \(number) needs a thread ID such as t41")
            return nil
        }
        guard let status = ReplyStatus(rawValue: words[1].lowercased()) else {
            problems.append("line \(number) needs a status of addressed, declined or question")
            return nil
        }
        return Block(thread: thread, status: status, headerLine: number)
    }
}
