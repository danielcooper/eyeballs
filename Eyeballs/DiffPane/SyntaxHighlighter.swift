import Foundation

/// The languages the lightweight highlighter knows, picked from a file's extension.
enum CodeLanguage: Hashable, Sendable {
    case swift, typeScript, python, go, rust, json, yaml, shell, plain

    init(path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "swift": self = .swift
        case "ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts": self = .typeScript
        case "py", "pyi": self = .python
        case "go": self = .go
        case "rs": self = .rust
        case "json", "jsonc": self = .json
        case "yml", "yaml": self = .yaml
        case "sh", "bash", "zsh", "command": self = .shell
        default: self = name == "dockerfile" || name.hasPrefix(".env") ? .shell : .plain
        }
    }
}

enum TokenKind: Hashable, Sendable {
    case keyword, string, comment, number, type, function, key, variable
}

struct SyntaxToken: Hashable, Sendable {
    /// UTF-16 offsets into the line.
    var range: NSRange
    var kind: TokenKind
}

/// Colours strings, comments, numbers and keywords one line at a time.
///
/// It is deliberately simple and fast. A block comment that spans lines is only recognised on
/// lines that start with `*`, which covers doc comments. Tree-sitter replaces this later.
enum SyntaxHighlighter {
    static func tokens(in line: String, language: CodeLanguage) -> [SyntaxToken] {
        guard language != .plain, !line.isEmpty else { return [] }
        var scanner = LineScanner(text: Array(line.utf16), rules: LanguageRules.rules(for: language))
        return scanner.scan()
    }
}

private struct LanguageRules: Sendable {
    var keywords: Set<String>
    var constants: Set<String>
    var lineComment: [UInt16]?
    var hashComments = false
    var blockComments = false
    var quotes: Set<UInt16>
    var capitalisedAreTypes = false
    var dollarVariables = false
    var keysBeforeColon = false
    var isYAML = false

    static func rules(for language: CodeLanguage) -> LanguageRules {
        switch language {
        case .swift:
            LanguageRules(
                keywords: [
                    "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
                    "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else",
                    "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func", "get", "guard",
                    "if", "import", "in", "indirect", "init", "inout", "internal", "is", "isolated", "lazy", "let",
                    "mutating", "nonisolated", "nonmutating", "open", "operator", "optional", "override",
                    "precedencegroup", "private", "protocol", "public", "repeat", "required", "rethrows", "return",
                    "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "try",
                    "typealias", "unowned", "var", "weak", "where", "while", "willSet", "consuming", "borrowing",
                    "sending", "Self", "self",
                ],
                constants: ["true", "false", "nil"],
                lineComment: Array("//".utf16), blockComments: true,
                quotes: [quote], capitalisedAreTypes: true)
        case .typeScript:
            LanguageRules(
                keywords: [
                    "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor",
                    "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export",
                    "extends", "finally", "for", "from", "function", "get", "if", "implements", "import", "in",
                    "instanceof", "interface", "keyof", "let", "namespace", "new", "of", "private", "protected",
                    "public", "readonly", "return", "set", "static", "super", "switch", "this", "throw", "try",
                    "type", "typeof", "var", "void", "while", "with", "yield", "satisfies",
                ],
                constants: ["true", "false", "null", "undefined", "NaN", "Infinity"],
                lineComment: Array("//".utf16), blockComments: true,
                quotes: [quote, apostrophe, backtick], capitalisedAreTypes: true)
        case .python:
            LanguageRules(
                keywords: [
                    "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                    "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
                    "match", "case", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with",
                    "yield", "self",
                ],
                constants: ["True", "False", "None"],
                hashComments: true, quotes: [quote, apostrophe], capitalisedAreTypes: true)
        case .go:
            LanguageRules(
                keywords: [
                    "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
                    "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
                    "struct", "switch", "type", "var",
                ],
                constants: ["true", "false", "nil", "iota"],
                lineComment: Array("//".utf16), blockComments: true,
                quotes: [quote, apostrophe, backtick], capitalisedAreTypes: true)
        case .rust:
            LanguageRules(
                keywords: [
                    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                    "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
                    "return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where",
                    "while",
                ],
                constants: ["true", "false", "None", "Some", "Ok", "Err"],
                lineComment: Array("//".utf16), blockComments: true,
                quotes: [quote], capitalisedAreTypes: true)
        case .json:
            LanguageRules(keywords: [], constants: ["true", "false", "null"], quotes: [quote], keysBeforeColon: true)
        case .yaml:
            LanguageRules(
                keywords: [], constants: ["true", "false", "null", "yes", "no", "on", "off", "~"],
                hashComments: true, quotes: [quote, apostrophe], isYAML: true)
        case .shell:
            LanguageRules(
                keywords: [
                    "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
                    "function", "return", "export", "local", "readonly", "set", "unset", "exit", "source", "shift",
                    "trap", "eval", "exec", "echo", "cd",
                ],
                constants: ["true", "false"],
                hashComments: true, quotes: [quote, apostrophe, backtick], dollarVariables: true)
        case .plain:
            LanguageRules(keywords: [], constants: [], quotes: [])
        }
    }
}

private let quote = UInt16(UInt8(ascii: "\""))
private let apostrophe = UInt16(UInt8(ascii: "'"))
private let backtick = UInt16(UInt8(ascii: "`"))
private let backslash = UInt16(UInt8(ascii: "\\"))
private let slash = UInt16(UInt8(ascii: "/"))
private let star = UInt16(UInt8(ascii: "*"))
private let hash = UInt16(UInt8(ascii: "#"))
private let colon = UInt16(UInt8(ascii: ":"))
private let dollar = UInt16(UInt8(ascii: "$"))
private let openParen = UInt16(UInt8(ascii: "("))
private let openBrace = UInt16(UInt8(ascii: "{"))
private let closeBrace = UInt16(UInt8(ascii: "}"))
private let at = UInt16(UInt8(ascii: "@"))
private let dash = UInt16(UInt8(ascii: "-"))
private let space = UInt16(UInt8(ascii: " "))
private let tab = UInt16(UInt8(ascii: "\t"))

private struct LineScanner {
    let text: [UInt16]
    let rules: LanguageRules
    var tokens: [SyntaxToken] = []
    var index = 0

    init(text: [UInt16], rules: LanguageRules) {
        self.text = text
        self.rules = rules
    }

    mutating func scan() -> [SyntaxToken] {
        if startsDocCommentContinuation() {
            return [SyntaxToken(range: NSRange(location: 0, length: text.count), kind: .comment)]
        }
        if rules.isYAML { scanYAMLKey() }
        while index < text.count {
            let character = text[index]
            if startsComment() {
                add(index, text.count, .comment)
                break
            } else if rules.blockComments, character == slash, peek(1) == star {
                let start = index
                index += 2
                while index < text.count, !(text[index] == star && peek(1) == slash) { index += 1 }
                index = min(text.count, index + 2)
                add(start, index, .comment)
            } else if rules.quotes.contains(character) {
                scanString(closingWith: character)
            } else if isDigit(character), !previousIsIdentifier() {
                scanNumber()
            } else if rules.dollarVariables, character == dollar {
                scanShellVariable()
            } else if isIdentifierStart(character) || (character == at && rules.capitalisedAreTypes) {
                scanWord()
            } else {
                index += 1
            }
        }
        return tokens
    }

    private func startsDocCommentContinuation() -> Bool {
        guard rules.blockComments else { return false }
        guard let first = text.firstIndex(where: { $0 != space && $0 != tab }), text[first] == star else { return false }
        let next = first + 1 < text.count ? text[first + 1] : space
        return next == space || next == slash || next == star || first + 1 == text.count
    }

    private func startsComment() -> Bool {
        if let marker = rules.lineComment, matches(marker) { return true }
        guard rules.hashComments, text[index] == hash else { return false }
        return index == 0 || text[index - 1] == space || text[index - 1] == tab
    }

    private mutating func scanString(closingWith delimiter: UInt16) {
        let start = index
        index += 1
        while index < text.count {
            if text[index] == backslash, delimiter != apostrophe || !rules.dollarVariables {
                index += 2
                continue
            }
            if text[index] == delimiter {
                index += 1
                break
            }
            index += 1
        }
        index = min(index, text.count)
        let isKey = rules.keysBeforeColon && nextNonSpace(from: index) == colon
        add(start, index, isKey ? .key : .string)
    }

    private mutating func scanNumber() {
        let start = index
        while index < text.count, isNumberPart(text[index]) { index += 1 }
        add(start, index, .number)
    }

    private mutating func scanShellVariable() {
        let start = index
        index += 1
        if index < text.count, text[index] == openBrace {
            while index < text.count, text[index] != closeBrace { index += 1 }
            index = min(text.count, index + 1)
        } else {
            while index < text.count, isIdentifierPart(text[index]) || isDigit(text[index]) { index += 1 }
        }
        if index - start > 1 { add(start, index, .variable) }
    }

    private mutating func scanWord() {
        let start = index
        index += 1
        while index < text.count, isIdentifierPart(text[index]) { index += 1 }
        let word = String(decoding: text[start..<index], as: UTF16.self)
        if text[start] == at {
            add(start, index, .keyword)
        } else if rules.keywords.contains(word) {
            add(start, index, .keyword)
        } else if rules.constants.contains(word) {
            add(start, index, .number)
        } else if rules.capitalisedAreTypes, let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
            add(start, index, .type)
        } else if !rules.dollarVariables, nextNonSpace(from: index) == openParen {
            add(start, index, .function)
        }
    }

    /// YAML keys: the word before the first `:` on a line, after any indent and list dash.
    private mutating func scanYAMLKey() {
        var position = 0
        while position < text.count, text[position] == space || text[position] == tab { position += 1 }
        if position < text.count, text[position] == dash, position + 1 < text.count, text[position + 1] == space { position += 2 }
        let start = position
        while position < text.count, text[position] != colon, text[position] != hash, text[position] != quote { position += 1 }
        guard position < text.count, text[position] == colon, position > start,
              position + 1 == text.count || text[position + 1] == space else { return }
        add(start, position, .key)
        index = position + 1
    }

    private func matches(_ marker: [UInt16]) -> Bool {
        guard index + marker.count <= text.count else { return false }
        return Array(text[index..<index + marker.count]) == marker
    }

    private func peek(_ offset: Int) -> UInt16? {
        index + offset < text.count ? text[index + offset] : nil
    }

    private func nextNonSpace(from position: Int) -> UInt16? {
        var position = position
        while position < text.count, text[position] == space || text[position] == tab { position += 1 }
        return position < text.count ? text[position] : nil
    }

    private func previousIsIdentifier() -> Bool {
        index > 0 && isIdentifierPart(text[index - 1])
    }

    private mutating func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
        guard end > start else { return }
        tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind))
    }

    private func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    private func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || (unit == dollar && !rules.dollarVariables)
    }

    private func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }

    private func isNumberPart(_ unit: UInt16) -> Bool {
        isDigit(unit) || unit == 95 || unit == 46 || (unit >= 65 && unit <= 70) || (unit >= 97 && unit <= 102)
            || unit == 120 || unit == 88 || unit == 111 || unit == 98
    }
}
