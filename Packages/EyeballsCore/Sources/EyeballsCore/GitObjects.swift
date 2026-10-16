import Foundation

/// A git object name: 40 hex digits for SHA-1 repositories, 64 for SHA-256 ones.
public struct ObjectID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// Lowercase hex.
    public let hex: String

    /// Returns nil unless `hex` is 40 or 64 hex digits. Uppercase digits are lowered.
    public init?(_ hex: some StringProtocol) {
        let lowered = hex.lowercased()
        guard lowered.utf8.count == 40 || lowered.utf8.count == 64,
              lowered.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { return nil }
        self.hex = lowered
    }

    init?(bytes: some Collection<UInt8>) {
        self.init(String(decoding: bytes, as: UTF8.self))
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = ObjectID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected 40 or 64 hex digits, got \(text.count) characters"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    /// True for the all-zero name git uses for "no object", as on the old side of an added file.
    public var isZero: Bool { hex.utf8.allSatisfy { $0 == 0x30 } }

    /// The first 7 digits, as `git log --oneline` shows them.
    public var short: String { String(hex.prefix(7)) }

    public var description: String { hex }

    public static func < (lhs: ObjectID, rhs: ObjectID) -> Bool { lhs.hex < rhs.hex }
}

/// A path inside a repository, kept as the exact bytes git stores.
///
/// Git paths need not be UTF-8. `string` is for display; compare and look up paths by `bytes`.
public struct GitPath: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let bytes: [UInt8]

    public init(bytes: some Sequence<UInt8>) {
        self.bytes = Array(bytes)
    }

    public init(_ string: String) {
        self.bytes = Array(string.utf8)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// The path as text, with any bytes that are not UTF-8 shown as U+FFFD.
    public var string: String { String(decoding: bytes, as: UTF8.self) }

    /// The path as text, or nil when it is not valid UTF-8 and so cannot be passed to git as an argument.
    public var exactString: String? { String(validating: bytes, as: UTF8.self) }

    public var description: String { string }

    public static func < (lhs: GitPath, rhs: GitPath) -> Bool { lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
}

/// A tree entry's mode, such as 100644 for a regular file.
public struct FileMode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Parses an octal mode such as `100755`.
    public init?(octal: some Collection<UInt8>) {
        guard !octal.isEmpty, octal.count <= 7 else { return nil }
        var value: UInt32 = 0
        for byte in octal {
            guard (0x30...0x37).contains(byte) else { return nil }
            value = value * 8 + UInt32(byte - 0x30)
        }
        self.rawValue = value
    }

    public static let regular = FileMode(rawValue: 0o100644)
    public static let executable = FileMode(rawValue: 0o100755)
    public static let symlink = FileMode(rawValue: 0o120000)
    public static let submodule = FileMode(rawValue: 0o160000)
    public static let directory = FileMode(rawValue: 0o040000)

    /// True for the all-zero mode git uses for a side that does not exist.
    public var isAbsent: Bool { rawValue == 0 }
    public var isSymlink: Bool { self == .symlink }
    public var isSubmodule: Bool { self == .submodule }

    public var description: String { String(rawValue, radix: 8) }
}

/// One side of a diff, as GitHub's LEFT and RIGHT.
public enum DiffSide: String, Hashable, Sendable, Codable {
    case base
    case head
}
