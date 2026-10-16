/// A thread, shown as `t41`. You can type it as `t41` or `41`.
public struct ThreadID: PrefixedID {
    public static let prefix: Character = "t"
    public let number: Int
    public init(_ number: Int) { self.number = number }
}

/// A stack, shown as `s3`.
public struct StackID: PrefixedID {
    public static let prefix: Character = "s"
    public let number: Int
    public init(_ number: Int) { self.number = number }
}

/// A comment, shown as `c210`.
public struct CommentID: PrefixedID {
    public static let prefix: Character = "c"
    public let number: Int
    public init(_ number: Int) { self.number = number }
}

/// The stack a command names with `--stack`: an ID such as `s3`, or any branch in the stack.
public enum StackReference: Hashable, Sendable, Codable, CustomStringConvertible {
    case id(StackID)
    case branch(String)

    /// `s3` and `3` name stack 3. Anything else names a branch. Returns nil for empty text.
    public init?(parsing text: String) {
        if let id = StackID(parsing: text) {
            self = .id(id)
        } else if text.isEmpty || text.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return nil
        } else {
            self = .branch(text)
        }
    }

    public var description: String {
        switch self {
        case .id(let id): id.description
        case .branch(let name): name
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(StackID.self, forKey: .id) {
            self = .id(id)
        } else {
            self = .branch(try container.decode(String.self, forKey: .branch))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .id(let id): try container.encode(id, forKey: .id)
        case .branch(let name): try container.encode(name, forKey: .branch)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, branch
    }
}

/// A positive integer ID shown with a one-letter prefix, such as `t41`.
///
/// It encodes as the prefixed string and decodes from `"t41"`, `"41"` or `41`.
public protocol PrefixedID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    static var prefix: Character { get }
    var number: Int { get }
    init(_ number: Int)
}

extension PrefixedID {
    /// Accepts the prefix in either case, or no prefix. Rejects zero, signs, spaces and leading
    /// zeros, so each ID has one spelling.
    public init?(parsing text: String) {
        var digits = Substring(text)
        if let first = digits.first, first.lowercased() == String(Self.prefix) {
            digits = digits.dropFirst()
        }
        guard let firstDigit = digits.first, firstDigit != "0", digits.count <= 18,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits) else { return nil }
        self.init(number)
    }

    public var description: String { "\(Self.prefix)\(number)" }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.number < rhs.number }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self), number > 0 {
            self.init(number)
            return
        }
        let text = try container.decode(String.self)
        guard let id = Self(parsing: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ID such as \(Self.prefix)41 or 41, got \(text.count) characters.")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
