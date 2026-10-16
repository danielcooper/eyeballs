import Foundation

/// One file's change between two commits. It maps onto the window's `FileItem`.
public struct DiffFile: Hashable, Sendable {
    /// The path on the base side. Nil for an added file.
    public var oldPath: GitPath?
    /// The path on the head side. Nil for a deleted file.
    public var newPath: GitPath?
    public var change: DiffChange
    public var oldMode: FileMode?
    public var newMode: FileMode?
    /// Nil on the side where the file does not exist, and nil when git did not print it.
    public var oldBlob: ObjectID?
    public var newBlob: ObjectID?
    /// The rename or copy similarity, 0 to 100.
    public var similarity: Int?
    public var isBinary: Bool
    public var hunks: [DiffHunk]

    public init(
        oldPath: GitPath?, newPath: GitPath?, change: DiffChange,
        oldMode: FileMode? = nil, newMode: FileMode? = nil, oldBlob: ObjectID? = nil, newBlob: ObjectID? = nil,
        similarity: Int? = nil, isBinary: Bool = false, hunks: [DiffHunk] = []
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.change = change
        self.oldMode = oldMode
        self.newMode = newMode
        self.oldBlob = oldBlob
        self.newBlob = newBlob
        self.similarity = similarity
        self.isBinary = isBinary
        self.hunks = hunks
    }

    /// The head-side path, or the base-side path for a deleted file.
    public var path: GitPath { newPath ?? oldPath ?? GitPath(bytes: []) }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .added }) } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .deleted }) } }

    public var isSymlink: Bool { oldMode?.isSymlink == true || newMode?.isSymlink == true }
    public var isSubmodule: Bool { oldMode?.isSubmodule == true || newMode?.isSubmodule == true }
    /// True when only the mode changed, such as a file becoming executable.
    public var isModeChangeOnly: Bool {
        change == .modified && hunks.isEmpty && !isBinary && oldMode != nil && newMode != nil && oldMode != newMode
    }
}

/// How a file changed. It maps onto the window's `FileChange`.
public enum DiffChange: String, Hashable, Sendable, CaseIterable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    /// The kind of entry changed, such as a file becoming a symlink.
    case typeChanged

    /// The letter `git diff --raw` and the `snapshot_file.change` column use.
    public var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        }
    }
}

/// One `@@` hunk. It maps onto the window's `HunkItem`.
public struct DiffHunk: Hashable, Sendable {
    /// The whole header line, for example `@@ -40,6 +40,9 @@ func get(_ path: String)`.
    public var header: String
    /// 1-based. With a count of 0, the line before the change, as git prints it.
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The text after the second `@@`, usually the enclosing function. Empty when git printed none.
    public var section: String
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "", lines: [DiffLine] = []) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }
}

/// One line inside a hunk. It maps onto the window's `LineItem`.
public struct DiffLine: Hashable, Sendable {
    public var kind: DiffLineKind
    /// The line's number on the base side. Nil for an added line.
    public var oldNumber: Int?
    /// The line's number on the head side. Nil for a deleted line.
    public var newNumber: Int?
    /// The line's exact bytes, without the newline but with any carriage return.
    public var content: [UInt8]
    /// True when git printed `\ No newline at end of file` after this line.
    public var hasNoNewline: Bool

    public init(kind: DiffLineKind, oldNumber: Int?, newNumber: Int?, content: [UInt8], hasNoNewline: Bool = false) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.content = content
        self.hasNoNewline = hasNoNewline
    }

    /// The line for display: bytes that are not UTF-8 become U+FFFD, and a trailing carriage return is dropped.
    public var text: String { FileText.displayString(content) }

    /// True when the line ends in a carriage return, as in a file with CRLF line endings.
    public var hasCarriageReturn: Bool { content.last == 0x0D }
}

public enum DiffLineKind: String, Hashable, Sendable {
    case context
    case added
    case deleted
}

/// A blob split into lines, so the pane can expand context and the porter can check its results.
public struct FileText: Hashable, Sendable {
    /// Each line's exact bytes, without the newline but with any carriage return.
    public var lines: [[UInt8]]
    /// False when the last line has no newline, or the file is empty.
    public var endsWithNewline: Bool

    public init(_ data: Data) {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
        let endsWithNewline = data.last == 0x0A
        if endsWithNewline || data.isEmpty { lines.removeLast() }
        self.lines = lines
        self.endsWithNewline = endsWithNewline
    }

    public var lineCount: Int { lines.count }

    /// Every line for display, as `DiffLine.text` shows it.
    public var strings: [String] { lines.map(FileText.displayString) }

    /// The lines in a 1-based, inclusive range, or nil when the range runs outside the file.
    public func lines(in range: ClosedRange<Int>) -> [[UInt8]]? {
        guard range.lowerBound >= 1, range.upperBound <= lines.count else { return nil }
        return Array(lines[(range.lowerBound - 1)...(range.upperBound - 1)])
    }

    static func displayString(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.last == 0x0D ? bytes.dropLast() : bytes[...], as: UTF8.self)
    }
}
