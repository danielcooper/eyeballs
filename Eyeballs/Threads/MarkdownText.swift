import SwiftUI

/// Shows a comment body as Markdown: paragraphs with inline code, emphasis and links, bullet
/// lists, quotes and fenced code blocks.
struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    init(_ source: String) {
        blocks = MarkdownBlock.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(item)
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.diffBorder).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
        case .code(let code):
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.codeBlock))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.diffBorder))
        }
    }

    private func inline(_ text: String) -> some View {
        Text(Self.attributed(text))
            .font(.system(size: 13))
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case bullets([String])
    case quote(String)
    case code(String)

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var quote: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            paragraph = []
            bullets = []
            quote = []
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
            } else if trimmed.isEmpty {
                flush()
            } else if let item = bulletText(trimmed) {
                if !paragraph.isEmpty || !quote.isEmpty {
                    let pending = bullets
                    bullets = []
                    flush()
                    bullets = pending
                }
                bullets.append(item)
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !bullets.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                if !bullets.isEmpty || !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            return String(line[line.index(dot, offsetBy: 2)...])
        }
        return nil
    }
}
