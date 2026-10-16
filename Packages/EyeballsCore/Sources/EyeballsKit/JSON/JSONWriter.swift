/// Writes compact JSON with no spaces.
///
/// It escapes every C0 control character, DEL and the C1 controls, so JSON printed to a terminal
/// can never carry an escape sequence. It leaves `/` alone, so paths read naturally.
struct JSONWriter {
    private(set) var output = ""

    mutating func write(_ value: JSONValue) {
        switch value {
        case .null:
            output += "null"
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .integer(let number):
            output += String(number)
        case .double(let number):
            output += number.isFinite ? String(number) : "null"
        case .string(let text):
            writeString(text)
        case .array(let elements):
            output += "["
            for (position, element) in elements.enumerated() {
                if position > 0 { output += "," }
                write(element)
            }
            output += "]"
        case .object(let object):
            output += "{"
            for (position, member) in object.members.enumerated() {
                if position > 0 { output += "," }
                writeString(member.key)
                output += ":"
                write(member.value)
            }
            output += "}"
        }
    }

    private mutating func writeString(_ text: String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where TerminalText.isControl(scalar):
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}
