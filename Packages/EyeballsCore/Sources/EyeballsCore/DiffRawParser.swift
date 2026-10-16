import Foundation

/// One entry of `git diff --raw -z --no-abbrev`: what changed, with exact paths, modes and blobs.
public struct RawDiffEntry: Hashable, Sendable {
    public var change: DiffChange
    /// The similarity after an R or C, 0 to 100.
    public var score: Int?
    /// Nil on the side where the file does not exist.
    public var oldMode: FileMode?
    public var newMode: FileMode?
    public var oldBlob: ObjectID?
    public var newBlob: ObjectID?
    /// Nil for an added file.
    public var oldPath: GitPath?
    /// Nil for a deleted file.
    public var newPath: GitPath?
}

/// Reads `git diff --raw -z --no-abbrev` output.
public enum RawDiffParser {
    /// Throws `DiffParseError` for anything but whole records. `line` in the error counts records.
    public static func parse(_ data: Data) throws -> [RawDiffEntry] {
        var fields = Array(data).split(separator: 0, omittingEmptySubsequences: false)
        if data.last == 0 || data.isEmpty { fields.removeLast() }
        var entries: [RawDiffEntry] = []
        var index = 0
        while index < fields.count {
            let record = entries.count + 1
            guard var entry = parseHeader(fields[index]) else {
                throw DiffParseError(line: record, problem: "Expected a raw diff record like \":100644 100644 <old> <new> M\".")
            }
            let pathCount = entry.change == .renamed || entry.change == .copied ? 2 : 1
            guard index + pathCount < fields.count else {
                throw DiffParseError(line: record, problem: "A raw diff record is missing its path.")
            }
            let first = GitPath(bytes: fields[index + 1])
            switch entry.change {
            case .added:
                entry.newPath = first
            case .deleted:
                entry.oldPath = first
            case .modified, .typeChanged:
                entry.oldPath = first
                entry.newPath = first
            case .renamed, .copied:
                entry.oldPath = first
                entry.newPath = GitPath(bytes: fields[index + 2])
            }
            entries.append(entry)
            index += 1 + pathCount
        }
        return entries
    }

    /// Reads `:<old mode> <new mode> <old blob> <new blob> <status>[score]`.
    static func parseHeader(_ field: ArraySlice<UInt8>) -> RawDiffEntry? {
        guard field.first == 0x3A else { return nil }
        let parts = field.dropFirst().split(separator: 0x20, omittingEmptySubsequences: false)
        guard parts.count == 5,
              let oldMode = FileMode(octal: parts[0]), let newMode = FileMode(octal: parts[1]),
              let oldBlob = ObjectID(bytes: parts[2]), let newBlob = ObjectID(bytes: parts[3]),
              let letter = parts[4].first
        else { return nil }
        let change: DiffChange
        switch letter {
        case 0x41: change = .added
        case 0x4D: change = .modified
        case 0x44: change = .deleted
        case 0x52: change = .renamed
        case 0x43: change = .copied
        case 0x54: change = .typeChanged
        default: return nil
        }
        var score: Int?
        if parts[4].count > 1 {
            var scanner = ByteScanner(parts[4].dropFirst())
            guard let value = scanner.number(), scanner.rest.isEmpty else { return nil }
            score = value
        }
        return RawDiffEntry(
            change: change, score: score,
            oldMode: oldMode.isAbsent ? nil : oldMode, newMode: newMode.isAbsent ? nil : newMode,
            oldBlob: oldBlob.isZero ? nil : oldBlob, newBlob: newBlob.isZero ? nil : newBlob
        )
    }
}

/// One entry of `git diff --numstat -z`.
public struct NumstatEntry: Hashable, Sendable {
    /// Nil for a binary file, which git counts as `-`.
    public var additions: Int?
    public var deletions: Int?
    /// Set for renames and copies.
    public var oldPath: GitPath?
    public var path: GitPath
}

/// Reads `git diff --numstat -z` output.
public enum NumstatParser {
    /// Throws `DiffParseError` for anything but whole records. `line` in the error counts records.
    public static func parse(_ data: Data) throws -> [NumstatEntry] {
        var reader = FieldReader(bytes: Array(data))
        var entries: [NumstatEntry] = []
        while !reader.isAtEnd {
            reader.record = entries.count + 1
            let additions = try count(try reader.field(endingWith: 0x09), record: reader.record)
            let deletions = try count(try reader.field(endingWith: 0x09), record: reader.record)
            if reader.skip(0) {
                let old = try reader.field(endingWith: 0)
                let new = try reader.field(endingWith: 0)
                entries.append(NumstatEntry(additions: additions, deletions: deletions, oldPath: GitPath(bytes: old), path: GitPath(bytes: new)))
            } else {
                let path = try reader.field(endingWith: 0)
                entries.append(NumstatEntry(additions: additions, deletions: deletions, oldPath: nil, path: GitPath(bytes: path)))
            }
        }
        return entries
    }

    /// A count, or nil for git's `-`.
    private static func count(_ field: ArraySlice<UInt8>, record: Int) throws -> Int? {
        if field.elementsEqual([0x2D]) { return nil }
        var scanner = ByteScanner(field)
        guard let value = scanner.number(), scanner.rest.isEmpty else {
            throw DiffParseError(line: record, problem: "Expected a line count or \"-\" in a numstat record.")
        }
        return value
    }
}

/// Reads fields that each end in a known byte.
private struct FieldReader {
    let bytes: [UInt8]
    var index = 0
    var record = 1

    var isAtEnd: Bool { index >= bytes.count }

    mutating func skip(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func field(endingWith terminator: UInt8) throws -> ArraySlice<UInt8> {
        guard let end = bytes[index...].firstIndex(of: terminator) else {
            throw DiffParseError(line: record, problem: "A numstat record ends early.")
        }
        defer { index = end + 1 }
        return bytes[index..<end]
    }
}
