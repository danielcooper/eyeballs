/// Why a JSON document could not be read. It names the byte offset and never quotes the input.
public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public var offset: Int
    public var reason: String

    public var description: String { "Invalid JSON at byte \(offset): \(reason)." }
}

/// A strict JSON parser that keeps object key order.
struct JSONParser {
    /// Deep enough for every Eyeballs message; shallow enough that a hostile request of a million
    /// `[` characters cannot overflow the stack.
    static let maximumDepth = 64

    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw failure("unexpected text after the value") }
        return value
    }

    private mutating func parseValue() throws -> JSONValue {
        guard let byte = peek() else { throw failure("the document ends too early") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw failure("expected a value")
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enterNesting()
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            depth -= 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw failure("expected a quoted key") }
            let key = try parseString()
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { throw failure("expected a colon after the key") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "}"):
                index += 1
                depth -= 1
                return .object(object)
            default:
                throw failure("expected a comma or a closing brace")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enterNesting()
        index += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            depth -= 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                depth -= 1
                return .array(elements)
            default:
                throw failure("expected a comma or a closing bracket")
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var utf8: [UInt8] = []
        while true {
            guard let byte = peek() else { throw failure("a string is not closed") }
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                try parseEscape(into: &utf8)
            case 0..<0x20:
                throw failure("a string holds an unescaped control character")
            default:
                utf8.append(byte)
                index += 1
            }
        }
    }

    private mutating func parseEscape(into utf8: inout [UInt8]) throws {
        guard let byte = peek() else { throw failure("a string is not closed") }
        index += 1
        switch byte {
        case UInt8(ascii: "\""): utf8.append(UInt8(ascii: "\""))
        case UInt8(ascii: "\\"): utf8.append(UInt8(ascii: "\\"))
        case UInt8(ascii: "/"): utf8.append(UInt8(ascii: "/"))
        case UInt8(ascii: "b"): utf8.append(0x08)
        case UInt8(ascii: "f"): utf8.append(0x0C)
        case UInt8(ascii: "n"): utf8.append(0x0A)
        case UInt8(ascii: "r"): utf8.append(0x0D)
        case UInt8(ascii: "t"): utf8.append(0x09)
        case UInt8(ascii: "u"):
            let scalar = try parseUnicodeEscape()
            utf8.append(contentsOf: Array(String(Character(scalar)).utf8))
        default:
            throw failure("a string holds an unknown escape")
        }
    }

    /// Reads the digits after `\u`, joining a surrogate pair. A lone surrogate becomes U+FFFD.
    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let first = try parseHexQuad()
        if (0xD800...0xDBFF).contains(first) {
            let save = index
            if peek() == UInt8(ascii: "\\"), peek(at: index + 1) == UInt8(ascii: "u") {
                index += 2
                let second = try parseHexQuad()
                if (0xDC00...0xDFFF).contains(second) {
                    let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    return Unicode.Scalar(combined) ?? "\u{FFFD}"
                }
                index = save
            }
            return "\u{FFFD}"
        }
        return Unicode.Scalar(first) ?? "\u{FFFD}"
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw failure("a \\u escape needs 4 hex digits") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw failure("a \\u escape needs 4 hex digits")
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        var isInteger = true
        if peek() == UInt8(ascii: "-") { index += 1 }
        guard let first = peek(), isDigit(first) else { throw failure("a number needs digits") }
        if first == UInt8(ascii: "0") {
            index += 1
        } else {
            skipDigits()
        }
        if peek() == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            guard let digit = peek(), isDigit(digit) else { throw failure("a number needs digits after the point") }
            skipDigits()
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { index += 1 }
            guard let digit = peek(), isDigit(digit) else { throw failure("a number needs digits in its exponent") }
            skipDigits()
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if isInteger, let value = Int64(text) { return .integer(value) }
        guard let value = Double(text), value.isFinite else { throw failure("a number is too large") }
        return .double(value)
    }

    private mutating func expectLiteral(_ literal: StaticString) throws {
        let expected = literal.withUTF8Buffer { Array($0) }
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw failure("expected a value")
        }
        index += expected.count
    }

    private mutating func enterNesting() throws {
        depth += 1
        guard depth <= Self.maximumDepth else { throw failure("values are nested more than \(Self.maximumDepth) deep") }
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    private mutating func skipDigits() {
        while let byte = peek(), isDigit(byte) { index += 1 }
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private func peek() -> UInt8? { peek(at: index) }

    private func peek(at position: Int) -> UInt8? {
        position < bytes.count ? bytes[position] : nil
    }

    private func failure(_ reason: String) -> JSONParseError {
        JSONParseError(offset: index, reason: reason)
    }
}
