/// Turns any `Encodable` into a `JSONValue`, keeping keys in the order `encode(to:)` writes them.
///
/// A nil optional property becomes `null` rather than vanishing, so every result object carries
/// every key, such as `"next_page":null`.
final class JSONValueEncoder: Encoder {
    let node: EncodingNode
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    static func encode(_ value: some Encodable) throws -> JSONValue {
        let root = EncodingNode()
        try encode(value, into: root, codingPath: [])
        return root.finish()
    }

    static func encode<T: Encodable>(_ value: T, into node: EncodingNode, codingPath: [any CodingKey]) throws {
        if let json = value as? JSONValue {
            node.kind = .value(json)
            return
        }
        try value.encode(to: JSONValueEncoder(node: node, codingPath: codingPath))
    }

    init(node: EncodingNode, codingPath: [any CodingKey]) {
        self.node = node
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        node.becomeObject()
        return KeyedEncodingContainer(KeyedNodeContainer<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        node.becomeArray()
        return UnkeyedNodeContainer(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleValueNodeContainer(node: node, codingPath: codingPath)
    }
}

/// One value under construction. Containers hold a reference, so a nested container can fill
/// its slot after the parent has moved on.
final class EncodingNode {
    enum Kind {
        case empty
        case value(JSONValue)
        case object([(key: String, node: EncodingNode)])
        case array([EncodingNode])
    }

    var kind = Kind.empty

    func becomeObject() {
        if case .object = kind { return }
        kind = .object([])
    }

    func becomeArray() {
        if case .array = kind { return }
        kind = .array([])
    }

    /// The node for `key`. Writing the same key twice replaces the first value in place.
    func member(_ key: String) -> EncodingNode {
        guard case .object(var members) = kind else { preconditionFailure("member(_:) needs an object node") }
        if let existing = members.first(where: { $0.key == key }) {
            existing.node.kind = .empty
            return existing.node
        }
        let child = EncodingNode()
        members.append((key, child))
        kind = .object(members)
        return child
    }

    func appendElement() -> EncodingNode {
        guard case .array(var elements) = kind else { preconditionFailure("appendElement() needs an array node") }
        let child = EncodingNode()
        elements.append(child)
        kind = .array(elements)
        return child
    }

    var elementCount: Int {
        if case .array(let elements) = kind { return elements.count }
        return 0
    }

    func finish() -> JSONValue {
        switch kind {
        case .empty:
            return .object(JSONObject())
        case .value(let value):
            return value
        case .object(let members):
            var object = JSONObject()
            for member in members { object[member.key] = member.node.finish() }
            return .object(object)
        case .array(let elements):
            return .array(elements.map { $0.finish() })
        }
    }
}

private func jsonNumber(_ value: Double, codingPath: [any CodingKey]) throws -> JSONValue {
    guard value.isFinite else {
        throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "JSON cannot hold infinity or NaN."))
    }
    return .double(value)
}

private func jsonNumber(_ value: some BinaryInteger) -> JSONValue {
    if let exact = Int64(exactly: value) { return .integer(exact) }
    return .double(Double(value))
}

private struct KeyedNodeContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: EncodingNode
    let codingPath: [any CodingKey]

    private func set(_ value: JSONValue, _ key: Key) {
        node.member(key.stringValue).kind = .value(value)
    }

    mutating func encodeNil(forKey key: Key) throws { set(.null, key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { set(.bool(value), key) }
    mutating func encode(_ value: String, forKey key: Key) throws { set(.string(value), key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { set(try jsonNumber(value, codingPath: codingPath + [key]), key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { set(try jsonNumber(Double(value), codingPath: codingPath + [key]), key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { set(jsonNumber(value), key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { set(jsonNumber(value), key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { set(jsonNumber(value), key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { set(jsonNumber(value), key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { set(jsonNumber(value), key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { set(jsonNumber(value), key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { set(jsonNumber(value), key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { set(jsonNumber(value), key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { set(jsonNumber(value), key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { set(jsonNumber(value), key) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try JSONValueEncoder.encode(value, into: node.member(key.stringValue), codingPath: codingPath + [key])
    }

    // Synthesized Codable calls these for optional properties. The standard versions skip nil;
    // these write null instead, so a missing value still shows its key.
    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws { try encodeOrNull(value, key) }
    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws { try encodeOrNull(value, key) }

    private mutating func encodeOrNull<T: Encodable>(_ value: T?, _ key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let child = node.member(key.stringValue)
        child.becomeObject()
        return KeyedEncodingContainer(KeyedNodeContainer<NestedKey>(node: child, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let child = node.member(key.stringValue)
        child.becomeArray()
        return UnkeyedNodeContainer(node: child, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> any Encoder {
        JSONValueEncoder(node: node.member(JSONKey.superKey.stringValue), codingPath: codingPath + [JSONKey.superKey])
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        JSONValueEncoder(node: node.member(key.stringValue), codingPath: codingPath + [key])
    }
}

private struct UnkeyedNodeContainer: UnkeyedEncodingContainer {
    let node: EncodingNode
    let codingPath: [any CodingKey]
    var count: Int { node.elementCount }

    private var nextPath: [any CodingKey] { codingPath + [JSONKey(intValue: count)!] }

    mutating func encodeNil() throws { node.appendElement().kind = .value(.null) }
    mutating func encode(_ value: Bool) throws { node.appendElement().kind = .value(.bool(value)) }
    mutating func encode(_ value: String) throws { node.appendElement().kind = .value(.string(value)) }
    mutating func encode(_ value: Double) throws { node.appendElement().kind = .value(try jsonNumber(value, codingPath: nextPath)) }
    mutating func encode(_ value: Float) throws { node.appendElement().kind = .value(try jsonNumber(Double(value), codingPath: nextPath)) }
    mutating func encode(_ value: Int) throws { node.appendElement().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int8) throws { node.appendElement().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int16) throws { node.appendElement().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int32) throws { node.appendElement().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int64) throws { node.appendElement().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt) throws { node.appendElement().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt8) throws { node.appendElement().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt16) throws { node.appendElement().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt32) throws { node.appendElement().kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt64) throws { node.appendElement().kind = .value(jsonNumber(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let path = nextPath
        try JSONValueEncoder.encode(value, into: node.appendElement(), codingPath: path)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let path = nextPath
        let child = node.appendElement()
        child.becomeObject()
        return KeyedEncodingContainer(KeyedNodeContainer<NestedKey>(node: child, codingPath: path))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let path = nextPath
        let child = node.appendElement()
        child.becomeArray()
        return UnkeyedNodeContainer(node: child, codingPath: path)
    }

    mutating func superEncoder() -> any Encoder {
        let path = nextPath
        return JSONValueEncoder(node: node.appendElement(), codingPath: path)
    }
}

private struct SingleValueNodeContainer: SingleValueEncodingContainer {
    let node: EncodingNode
    let codingPath: [any CodingKey]

    mutating func encodeNil() throws { node.kind = .value(.null) }
    mutating func encode(_ value: Bool) throws { node.kind = .value(.bool(value)) }
    mutating func encode(_ value: String) throws { node.kind = .value(.string(value)) }
    mutating func encode(_ value: Double) throws { node.kind = .value(try jsonNumber(value, codingPath: codingPath)) }
    mutating func encode(_ value: Float) throws { node.kind = .value(try jsonNumber(Double(value), codingPath: codingPath)) }
    mutating func encode(_ value: Int) throws { node.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int8) throws { node.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int16) throws { node.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int32) throws { node.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: Int64) throws { node.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt) throws { node.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt8) throws { node.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt16) throws { node.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt32) throws { node.kind = .value(jsonNumber(value)) }
    mutating func encode(_ value: UInt64) throws { node.kind = .value(jsonNumber(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try JSONValueEncoder.encode(value, into: node, codingPath: codingPath)
    }
}
