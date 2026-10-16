/// A range of lines in one file, written `PATH:A-B`, as in `at: Sources/API/Client.swift:40-58`.
///
/// Lines are 1-based and inclusive. `PATH:A` means the single line A. On the wire it is
/// `{"path":"…","start":40,"end":58}`, the shape of the `comment.at_ranges` column.
public struct LineSpan: Codable, Sendable, Hashable, CustomStringConvertible {
    public var path: String
    public var start: Int
    public var end: Int

    public init(path: String, start: Int, end: Int) {
        self.path = path
        self.start = start
        self.end = end
    }

    /// Splits at the last colon, so a path may hold colons itself. Throws a `bad_input` error.
    public init(parsing text: String) throws {
        guard let colon = text.lastIndex(of: ":") else {
            throw Self.shapeError("has no colon")
        }
        let path = String(text[..<colon]).trimmingWhitespace()
        let lines = text[text.index(after: colon)...]
        guard !path.isEmpty else { throw Self.shapeError("has no path before the colon") }

        let bounds = lines.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(bounds.count),
              let start = Self.lineNumber(bounds[0]),
              let end = bounds.count == 2 ? Self.lineNumber(bounds[1]) : start else {
            throw Self.shapeError("needs line numbers such as 40 or 40-58 after the colon")
        }
        guard start <= end else { throw Self.shapeError("ends before it starts") }
        self.init(path: path, start: start, end: end)
    }

    public var description: String {
        start == end ? "\(path):\(start)" : "\(path):\(start)-\(end)"
    }

    /// Nil when the span is not one an agent could have meant: an empty path or a bad range.
    var problem: String? {
        if path.isEmpty { return "has an empty path" }
        if start < 1 { return "starts before line 1" }
        if end < start { return "ends before it starts" }
        return nil
    }

    private static func lineNumber(_ text: Substring) -> Int? {
        guard let first = text.first, first != "0", text.count <= 9,
              text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    private static func shapeError(_ problem: String) -> EyeballsError {
        .badInput("A line range \(problem). Write it as PATH:A-B, for example Sources/App.swift:40-58.")
    }
}

/// Reads `--timeout` values: a whole number followed by `s`, `m` or `h`, such as `90s`, `30m`
/// or `2h`.
public enum DurationText {
    static let maximumSeconds = 100 * 24 * 3600

    /// Throws a `bad_input` error for anything else, including zero.
    public static func parse(_ text: String) throws -> Duration {
        let shapeError = EyeballsError.badInput("A duration must be a whole number followed by s, m or h, for example 90s, 30m or 2h.")
        let digits = text.dropLast()
        guard let unit = text.last, !digits.isEmpty, digits.count <= 9,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }), let amount = Int(digits) else {
            throw shapeError
        }
        let secondsPerUnit: Int
        switch unit {
        case "s": secondsPerUnit = 1
        case "m": secondsPerUnit = 60
        case "h": secondsPerUnit = 3600
        default: throw shapeError
        }
        guard amount > 0 else { throw EyeballsError.badInput("A duration must be longer than 0.") }
        let seconds = amount * secondsPerUnit
        guard seconds <= maximumSeconds else { throw EyeballsError.badInput("A duration must be 100 days or shorter.") }
        return .seconds(seconds)
    }

    /// The shortest of the three forms that shows `duration` exactly, such as `25m`.
    public static func format(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds > 0, seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds > 0, seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}

extension StringProtocol {
    func trimmingWhitespace() -> String {
        var text = Substring(self)
        while let first = text.first, first == " " || first == "\t" { text = text.dropFirst() }
        while let last = text.last, last == " " || last == "\t" { text = text.dropLast() }
        return String(text)
    }
}
