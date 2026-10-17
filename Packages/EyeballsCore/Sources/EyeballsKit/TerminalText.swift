/// Makes text from the app safe to print in a terminal.
///
/// Comment bodies and code come from repositories and agents, so they can hold an ESC that
/// would move the cursor, rewrite the screen or change the window title. Every control
/// character except tab and newline prints as a Swift-style escape instead, such as `\u{1b}`.
public enum TerminalText {
    public static func escape(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: needsEscape) else { return text }
        var escaped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if needsEscape(scalar) {
                escaped.append(contentsOf: "\\u{\(String(scalar.value, radix: 16))}".unicodeScalars)
            } else {
                escaped.append(scalar)
            }
        }
        return String(escaped)
    }

    /// C0 controls, DEL and the C1 controls. Some terminals act on C1 controls such as U+009B,
    /// which starts an escape sequence on its own.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        isControl(scalar) && scalar != "\t" && scalar != "\n"
    }
}
