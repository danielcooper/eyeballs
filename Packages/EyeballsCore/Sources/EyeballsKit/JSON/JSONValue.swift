import Foundation

/// Any JSON value, keeping the order of each object's keys.
///
/// Every message between the `eyeballs` command and the app passes through this type, so a
/// result prints with `schema` and `ok` first, exactly as the app built it. `JSONEncoder` and
/// `JSONSerialization` both lose key order.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// Encodes `value` in the order its `encode(to:)` writes keys. Nil optionals become `null`.
    public init(encoding value: some Encodable) throws {
        self = try JSONValueEncoder.encode(value)
    }

    /// Parses one JSON document. Throws `JSONParseError`.
    public init(parsing bytes: some Collection<UInt8>) throws {
        var parser = JSONParser(bytes: Array(bytes))
        self = try parser.parseDocument()
    }

    public init(parsing text: String) throws {
        try self.init(parsing: Array(text.utf8))
    }

    /// Decodes this value as `type`, using `JSONDecoder`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: serializedData())
    }

    /// Compact JSON on one line. Control characters are always escaped, so the text is safe to
    /// print to a terminal.
    public func serialized() -> String {
        var writer = JSONWriter()
        writer.write(self)
        return writer.output
    }

    public func serializedData() -> Data {
        Data(serialized().utf8)
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }
}

/// A JSON object whose keys keep the order they were added in.
public struct JSONObject: Sendable, Hashable {
    public struct Member: Sendable, Hashable {
        public var key: String
        public var value: JSONValue
    }

    public private(set) var members: [Member] = []

    public init() {}

    public init(_ pairs: KeyValuePairs<String, JSONValue>) {
        for (key, value) in pairs { self[key] = value }
    }

    public var keys: [String] { members.map(\.key) }
    public var isEmpty: Bool { members.isEmpty }

    /// Setting a key that exists replaces its value in place. Setting nil removes the key.
    public subscript(key: String) -> JSONValue? {
        get { members.first { $0.key == key }?.value }
        set {
            let index = members.firstIndex { $0.key == key }
            switch (index, newValue) {
            case let (index?, value?): members[index].value = value
            case let (index?, nil): members.remove(at: index)
            case let (nil, value?): members.append(Member(key: key, value: value))
            case (nil, nil): break
            }
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Int64.self) { self = .integer(value); return }
            if let value = try? container.decode(Double.self) { self = .double(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
        }
        if var container = try? decoder.unkeyedContainer() {
            var elements: [JSONValue] = []
            while !container.isAtEnd { elements.append(try container.decode(JSONValue.self)) }
            self = .array(elements)
            return
        }
        let container = try decoder.container(keyedBy: JSONKey.self)
        var object = JSONObject()
        for key in container.allKeys {
            object[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self = .object(object)
    }

    public func encode(to encoder: any Encoder) throws {
        if let encoder = encoder as? JSONValueEncoder {
            encoder.node.kind = .value(self)
            return
        }
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .double(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let elements):
            var container = encoder.unkeyedContainer()
            for element in elements { try container.encode(element) }
        case .object(let object):
            var container = encoder.container(keyedBy: JSONKey.self)
            for member in object.members { try container.encode(member.value, forKey: JSONKey(member.key)) }
        }
    }
}

extension JSONObject: Codable {
    public init(from decoder: any Decoder) throws {
        guard case .object(let object) = try JSONValue(from: decoder) else {
            throw DecodingError.typeMismatch(JSONObject.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected a JSON object."))
        }
        self = object
    }

    public func encode(to encoder: any Encoder) throws {
        try JSONValue.object(self).encode(to: encoder)
    }
}

/// A coding key made from any string.
struct JSONKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }

    static let superKey = JSONKey("super")
}
