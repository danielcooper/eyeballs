import Foundation

/// Reads `git diff` patch output byte by byte, so paths and lines that are not UTF-8 survive.
///
/// It reads what `git diff --full-index` prints for two commits or two blobs: renames, copies,
/// binary files, mode changes, symlinks, submodules, `\ No newline at end of file`, CRLF lines
/// and quoted paths. A type change arrives as two entries, a deletion and an addition, as git
/// prints it. Text before the first `diff --git` line is skipped.
public enum UnifiedDiffParser: Sendable {
    /// Throws `DiffParseError` when a hunk is cut short or a header cannot be read.
    public static func parse(_ data: Data) throws -> [DiffFile] {
        try parse(Array(data))
    }

    public static func parse(_ bytes: [UInt8]) throws -> [DiffFile] {
        var reader = PatchReader(lines: splitLines(bytes))
        var files: [DiffFile] = []
        while let line = reader.current {
            if line.starts(with: Prefix.diffGit) {
                files.append(try reader.readFile())
            } else if line.starts(with: Prefix.diffCombined) || line.starts(with: Prefix.diffCC) {
                throw DiffParseError(line: reader.lineNumber, problem: "Combined diffs of merge commits are not supported.")
            } else {
                reader.advance()
            }
        }
        return files
    }

    static func splitLines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        if bytes.last == 0x0A || bytes.isEmpty { lines.removeLast() }
        return lines
    }
}

/// A patch that could not be read. `line` is 1-based in the patch text.
public struct DiffParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var line: Int
    public var problem: String

    public var description: String { "Diff line \(line): \(problem)" }
}

enum Prefix {
    static let diffGit = Array("diff --git ".utf8)
    static let diffCombined = Array("diff --combined ".utf8)
    static let diffCC = Array("diff --cc ".utf8)
    static let hunk = Array("@@ ".utf8)
    static let minusFile = Array("--- ".utf8)
    static let plusFile = Array("+++ ".utf8)
    static let binaryFiles = Array("Binary files ".utf8)
    static let gitBinaryPatch = Array("GIT binary patch".utf8)
    static let oldMode = Array("old mode ".utf8)
    static let newMode = Array("new mode ".utf8)
    static let deletedFileMode = Array("deleted file mode ".utf8)
    static let newFileMode = Array("new file mode ".utf8)
    static let renameFrom = Array("rename from ".utf8)
    static let renameTo = Array("rename to ".utf8)
    static let copyFrom = Array("copy from ".utf8)
    static let copyTo = Array("copy to ".utf8)
    static let similarity = Array("similarity index ".utf8)
    static let index = Array("index ".utf8)
    static let devNull = Array("/dev/null".utf8)
    static let oldSide = Array("a/".utf8)
    static let newSide = Array("b/".utf8)
}

/// Walks a patch one line at a time.
struct PatchReader {
    let lines: [ArraySlice<UInt8>]
    var index = 0

    var current: ArraySlice<UInt8>? { index < lines.count ? lines[index] : nil }
    var lineNumber: Int { index + 1 }

    mutating func advance() { index += 1 }

    /// Reads one file, from its `diff --git` line to the line before the next file.
    mutating func readFile() throws -> DiffFile {
        let headerLine = lineNumber
        var header = FileHeader()
        header.gitLinePaths = Self.pathsInDiffGitLine(lines[index].dropFirst(Prefix.diffGit.count))
        advance()

        while let line = current, !Self.endsFileHeader(line) {
            header.read(line)
            advance()
        }

        if let line = current, line.starts(with: Prefix.minusFile) {
            header.minusLine = Self.pathInFileLine(line.dropFirst(Prefix.minusFile.count))
            advance()
            guard let plus = current, plus.starts(with: Prefix.plusFile) else {
                throw DiffParseError(line: lineNumber, problem: "Expected a \"+++\" line after the \"---\" line.")
            }
            header.plusLine = Self.pathInFileLine(plus.dropFirst(Prefix.plusFile.count))
            advance()
        }

        var file = try header.makeFile(line: headerLine)
        if let line = current, line.starts(with: Prefix.binaryFiles) {
            file.isBinary = true
            advance()
        } else if let line = current, line.starts(with: Prefix.gitBinaryPatch) {
            file.isBinary = true
            while let line = current, !line.starts(with: Prefix.diffGit) { advance() }
        }
        while let line = current, line.starts(with: Prefix.hunk) {
            file.hunks.append(try readHunk())
        }
        return file
    }

    mutating func readHunk() throws -> DiffHunk {
        let headerBytes = lines[index]
        guard var hunk = Self.parseHunkHeader(headerBytes) else {
            throw DiffParseError(line: lineNumber, problem: "Expected a hunk header like \"@@ -1,3 +1,4 @@\".")
        }
        advance()
        var oldLeft = hunk.oldCount
        var newLeft = hunk.newCount
        var oldNumber = hunk.oldStart
        var newNumber = hunk.newStart
        while oldLeft > 0 || newLeft > 0 {
            guard let line = current else {
                throw DiffParseError(line: lineNumber, problem: "The patch ended inside a hunk.")
            }
            let content = Array(line.dropFirst())
            switch line.first {
            case 0x20, nil:
                guard oldLeft > 0, newLeft > 0 else { throw tooManyLines() }
                hunk.lines.append(DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, content: content))
                oldNumber += 1
                newNumber += 1
                oldLeft -= 1
                newLeft -= 1
            case 0x2D:
                guard oldLeft > 0 else { throw tooManyLines() }
                hunk.lines.append(DiffLine(kind: .deleted, oldNumber: oldNumber, newNumber: nil, content: content))
                oldNumber += 1
                oldLeft -= 1
            case 0x2B:
                guard newLeft > 0 else { throw tooManyLines() }
                hunk.lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber, content: content))
                newNumber += 1
                newLeft -= 1
            case 0x5C:
                try markNoNewline(in: &hunk)
            default:
                throw DiffParseError(line: lineNumber, problem: "Expected a line starting with a space, \"-\", \"+\" or \"\\\" inside a hunk.")
            }
            advance()
        }
        if let line = current, line.first == 0x5C {
            try markNoNewline(in: &hunk)
            advance()
        }
        return hunk
    }

    private func tooManyLines() -> DiffParseError {
        DiffParseError(line: lineNumber, problem: "The hunk has more lines than its header counts.")
    }

    private func markNoNewline(in hunk: inout DiffHunk) throws {
        guard !hunk.lines.isEmpty else {
            throw DiffParseError(line: lineNumber, problem: "\"\\ No newline at end of file\" must follow a line.")
        }
        hunk.lines[hunk.lines.count - 1].hasNoNewline = true
    }

    static func endsFileHeader(_ line: ArraySlice<UInt8>) -> Bool {
        line.starts(with: Prefix.hunk) || line.starts(with: Prefix.minusFile) || line.starts(with: Prefix.binaryFiles)
            || line.starts(with: Prefix.gitBinaryPatch) || line.starts(with: Prefix.diffGit)
            || line.starts(with: Prefix.diffCC) || line.starts(with: Prefix.diffCombined)
    }

    /// Reads `@@ -12,3 +12,4 @@ section`. A missing count means 1.
    static func parseHunkHeader(_ line: ArraySlice<UInt8>) -> DiffHunk? {
        var scanner = ByteScanner(line)
        guard scanner.skip("@@ -"), let oldStart = scanner.number() else { return nil }
        let oldCount = scanner.skip(",") ? scanner.number() : 1
        guard let oldCount, scanner.skip(" +"), let newStart = scanner.number() else { return nil }
        let newCount = scanner.skip(",") ? scanner.number() : 1
        guard let newCount, scanner.skip(" @@") else { return nil }
        _ = scanner.skip(" ")
        return DiffHunk(
            header: String(decoding: line, as: UTF8.self),
            oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
            section: String(decoding: scanner.rest, as: UTF8.self)
        )
    }

    /// The two paths in `a/x b/x`, quoted or not, without their prefixes.
    ///
    /// Git's own line is ambiguous when an unquoted path holds a space, so this trusts it only when
    /// both halves name the same path. Renames and copies take their paths from their own lines.
    static func pathsInDiffGitLine(_ rest: ArraySlice<UInt8>) -> (old: GitPath, new: GitPath)? {
        if rest.first == 0x22 {
            guard let old = GitQuoting.unquote(rest), old.end < rest.endIndex, rest[old.end] == 0x20,
                  let new = GitQuoting.unquote(rest[(old.end + 1)...])
            else { return nil }
            return (strip(Prefix.oldSide, from: old.bytes), strip(Prefix.newSide, from: new.bytes))
        }
        guard rest.count % 2 == 1 else { return nil }
        let half = rest.count / 2
        let old = rest.prefix(half)
        let separator = rest[rest.startIndex + half]
        let new = rest.suffix(half)
        guard separator == 0x20, old.starts(with: Prefix.oldSide), new.starts(with: Prefix.newSide),
              old.dropFirst(2).elementsEqual(new.dropFirst(2))
        else { return nil }
        return (GitPath(bytes: old.dropFirst(2)), GitPath(bytes: new.dropFirst(2)))
    }

    /// The path in a `---` or `+++` line, still with its `a/` or `b/` prefix.
    static func pathInFileLine(_ rest: ArraySlice<UInt8>) -> FileLinePath {
        if rest.first == 0x22 {
            return GitQuoting.unquote(rest).map { .path($0.bytes) } ?? .unreadable
        }
        // Git adds a tab after a path that holds a space. An unquoted path never holds a tab.
        let path = rest.prefix { $0 != 0x09 }
        return path.elementsEqual(Prefix.devNull) ? .devNull : .path(Array(path))
    }

    static func strip(_ prefix: [UInt8], from bytes: [UInt8]) -> GitPath {
        GitPath(bytes: bytes.starts(with: prefix) ? bytes.dropFirst(prefix.count) : bytes[...])
    }
}

/// What a `---` or `+++` line names.
enum FileLinePath {
    case path([UInt8])
    case devNull
    case unreadable
}

/// What a file's extended header lines said.
struct FileHeader {
    var gitLinePaths: (old: GitPath, new: GitPath)?
    var minusLine: FileLinePath?
    var plusLine: FileLinePath?
    var oldMode: FileMode?
    var newMode: FileMode?
    var isAdded = false
    var isDeleted = false
    var renameFrom: GitPath?
    var renameTo: GitPath?
    var copyFrom: GitPath?
    var copyTo: GitPath?
    var similarity: Int?
    var oldBlob: ObjectID?
    var newBlob: ObjectID?

    mutating func read(_ line: ArraySlice<UInt8>) {
        if let mode = value(after: Prefix.oldMode, in: line) {
            oldMode = FileMode(octal: mode)
        } else if let mode = value(after: Prefix.newMode, in: line) {
            newMode = FileMode(octal: mode)
        } else if let mode = value(after: Prefix.deletedFileMode, in: line) {
            isDeleted = true
            oldMode = FileMode(octal: mode)
        } else if let mode = value(after: Prefix.newFileMode, in: line) {
            isAdded = true
            newMode = FileMode(octal: mode)
        } else if let path = value(after: Prefix.renameFrom, in: line) {
            renameFrom = GitQuoting.path(path)
        } else if let path = value(after: Prefix.renameTo, in: line) {
            renameTo = GitQuoting.path(path)
        } else if let path = value(after: Prefix.copyFrom, in: line) {
            copyFrom = GitQuoting.path(path)
        } else if let path = value(after: Prefix.copyTo, in: line) {
            copyTo = GitQuoting.path(path)
        } else if let score = value(after: Prefix.similarity, in: line) {
            var scanner = ByteScanner(score)
            similarity = scanner.number()
        } else if let blobs = value(after: Prefix.index, in: line) {
            readIndexLine(blobs)
        }
    }

    /// Reads `<old>..<new>` with an optional ` <mode>` after it.
    mutating func readIndexLine(_ text: ArraySlice<UInt8>) {
        let fields = text.split(separator: 0x20, maxSplits: 1)
        guard let names = fields.first else { return }
        let ends = names.split(separator: 0x2E, omittingEmptySubsequences: true)
        if ends.count == 2 {
            oldBlob = ObjectID(bytes: ends[0]).flatMap { $0.isZero ? nil : $0 }
            newBlob = ObjectID(bytes: ends[1]).flatMap { $0.isZero ? nil : $0 }
        }
        if fields.count == 2, let mode = FileMode(octal: fields[1]) {
            if oldMode == nil, !isAdded { oldMode = mode }
            if newMode == nil, !isDeleted { newMode = mode }
        }
    }

    func makeFile(line: Int) throws -> DiffFile {
        var change = DiffChange.modified
        var oldPath: GitPath?
        var newPath: GitPath?
        if let renameFrom, let renameTo {
            change = .renamed
            (oldPath, newPath) = (renameFrom, renameTo)
        } else if let copyFrom, let copyTo {
            change = .copied
            (oldPath, newPath) = (copyFrom, copyTo)
        } else {
            oldPath = Self.resolve(minusLine, prefix: Prefix.oldSide, otherwise: gitLinePaths?.old)
            newPath = Self.resolve(plusLine, prefix: Prefix.newSide, otherwise: gitLinePaths?.new)
            if isAdded {
                change = .added
                oldPath = nil
            } else if isDeleted {
                change = .deleted
                newPath = nil
            }
        }
        guard oldPath != nil || newPath != nil else {
            throw DiffParseError(line: line, problem: "Could not read the file's path from its header.")
        }
        return DiffFile(
            oldPath: oldPath, newPath: newPath, change: change,
            oldMode: isAdded ? nil : oldMode, newMode: isDeleted ? nil : newMode,
            oldBlob: oldBlob, newBlob: newBlob, similarity: similarity
        )
    }

    private static func resolve(_ line: FileLinePath?, prefix: [UInt8], otherwise fallback: GitPath?) -> GitPath? {
        switch line {
        case .path(let bytes): PatchReader.strip(prefix, from: bytes)
        case .devNull: nil
        case .unreadable, nil: fallback
        }
    }

    private func value(after prefix: [UInt8], in line: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        line.starts(with: prefix) ? line.dropFirst(prefix.count) : nil
    }
}

/// Git's C-style path quoting: `"a\tb"`, `"caf\303\251"`.
enum GitQuoting {
    /// A path that may be quoted.
    static func path(_ text: ArraySlice<UInt8>) -> GitPath {
        if text.first == 0x22, let quoted = unquote(text) {
            return GitPath(bytes: quoted.bytes)
        }
        return GitPath(bytes: text)
    }

    /// Reads a quoted string at the start of `text`. Returns its bytes and the index just after
    /// the closing quote, or nil when the quoting is broken.
    static func unquote(_ text: ArraySlice<UInt8>) -> (bytes: [UInt8], end: Int)? {
        guard text.first == 0x22 else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex + 1
        while index < text.endIndex {
            let byte = text[index]
            if byte == 0x22 { return (bytes, index + 1) }
            guard byte == 0x5C else {
                bytes.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < text.endIndex else { return nil }
            let escaped = text[index]
            switch escaped {
            case 0x61: bytes.append(0x07)
            case 0x62: bytes.append(0x08)
            case 0x74: bytes.append(0x09)
            case 0x6E: bytes.append(0x0A)
            case 0x76: bytes.append(0x0B)
            case 0x66: bytes.append(0x0C)
            case 0x72: bytes.append(0x0D)
            case 0x22, 0x5C: bytes.append(escaped)
            case 0x30...0x33:
                guard index + 2 < text.endIndex,
                      (0x30...0x37).contains(text[index + 1]), (0x30...0x37).contains(text[index + 2])
                else { return nil }
                bytes.append((escaped - 0x30) << 6 | (text[index + 1] - 0x30) << 3 | (text[index + 2] - 0x30))
                index += 2
            default:
                return nil
            }
            index += 1
        }
        return nil
    }
}

/// Reads ASCII tokens from a run of bytes.
struct ByteScanner {
    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    var rest: ArraySlice<UInt8> { bytes[index...] }

    /// Skips `literal` if the bytes continue with it.
    mutating func skip(_ literal: String) -> Bool {
        let expected = literal.utf8
        guard bytes[index...].starts(with: expected) else { return false }
        index += expected.count
        return true
    }

    /// Reads up to 9 decimal digits, so the value always fits an Int.
    mutating func number() -> Int? {
        var value = 0
        var digits = 0
        while index < bytes.endIndex, (0x30...0x39).contains(bytes[index]) {
            guard digits < 9 else { return nil }
            value = value * 10 + Int(bytes[index] - 0x30)
            digits += 1
            index += 1
        }
        return digits == 0 ? nil : value
    }
}
