import AppKit
import CoreText

/// Font and gutter numbers shared by every code row, and the wrapping rules built on them.
///
/// Row heights come from here, never from measuring live views. A plain ASCII line wraps by
/// arithmetic on the fixed character width. Any other line is laid out once with CoreText and
/// cached, because tabs, wide characters and fallback fonts break the arithmetic.
@MainActor
final class CodeMetrics {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let lineHeight: CGFloat = 18
    let markerWidth: CGFloat = 20
    let codeInset: CGFloat = 4
    let trailingPadding: CGFloat = 16
    let characterWidth: CGFloat
    /// From the top of one visual line to its text baseline.
    let baseline: CGFloat
    private(set) var numberColumnWidth: CGFloat = 44

    private var layoutCache: [LayoutKey: CodeLineLayout] = [:]

    init() {
        let probe = CTLineCreateWithAttributedString(NSAttributedString(string: "0", attributes: [.font: font]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        characterWidth = CGFloat(CTLineGetTypographicBounds(probe, &ascent, &descent, nil))
        baseline = ((lineHeight - (ascent + descent)) / 2 + ascent).rounded()
    }

    var gutterWidth: CGFloat { 2 * numberColumnWidth + markerWidth }
    var codeX: CGFloat { gutterWidth + codeInset }

    /// Sizes the line-number columns for the largest number in the layer. Returns true when the
    /// gutter changed, so every height must be worked out again.
    @discardableResult
    func fitNumbers(upTo largestLineNumber: Int) -> Bool {
        let digits = max(3, String(largestLineNumber).count)
        let width = (CGFloat(digits) * characterWidth + 20).rounded(.up)
        guard width != numberColumnWidth else { return false }
        numberColumnWidth = width
        layoutCache.removeAll()
        return true
    }

    func codeWidth(forRowWidth rowWidth: CGFloat) -> CGFloat {
        max(80, rowWidth - codeX - trailingPadding)
    }

    func columns(forRowWidth rowWidth: CGFloat) -> Int {
        max(8, Int((codeWidth(forRowWidth: rowWidth) / characterWidth).rounded(.down)))
    }

    func height(of text: String, isPlainASCII: Bool, rowWidth: CGFloat) -> CGFloat {
        CGFloat(layout(of: text, isPlainASCII: isPlainASCII, rowWidth: rowWidth).lines.count) * lineHeight
    }

    func layout(of text: String, isPlainASCII: Bool, rowWidth: CGFloat) -> CodeLineLayout {
        if isPlainASCII {
            let units = Array(text.utf16)
            let columns = columns(forRowWidth: rowWidth)
            guard units.count > columns else {
                return CodeLineLayout(lines: [NSRange(location: 0, length: units.count)], isPlainASCII: true, continuationIndent: 0)
            }
            let indent = Self.continuationIndentColumns(units, columns: columns)
            var lines: [NSRange] = []
            var start = 0
            var capacity = columns
            while start < units.count {
                let end = Self.breakPoint(in: units, from: start, capacity: capacity)
                lines.append(NSRange(location: start, length: end - start))
                start = end
                capacity = columns - indent
            }
            return CodeLineLayout(lines: lines, isPlainASCII: true, continuationIndent: CGFloat(indent) * characterWidth)
        }
        let key = LayoutKey(text: text, width: Int(codeWidth(forRowWidth: rowWidth)))
        if let cached = layoutCache[key] { return cached }
        let layout = measuredLayout(of: text, width: codeWidth(forRowWidth: rowWidth), columns: columns(forRowWidth: rowWidth))
        if layoutCache.count > 20_000 { layoutCache.removeAll() }
        layoutCache[key] = layout
        return layout
    }

    /// Wrapped lines start under the code's own indent, a little further in, so a wrap never
    /// looks like a new line of code.
    private static func continuationIndentColumns(_ units: [UInt16], columns: Int) -> Int {
        let leading = units.prefix { $0 == 0x20 }.count
        return min(leading + 4, columns / 2)
    }

    /// Where a visual line that starts at `start` ends: after the last space that fits, or at
    /// the column limit when no space falls in the last two thirds of the line.
    private static func breakPoint(in units: [UInt16], from start: Int, capacity: Int) -> Int {
        let limit = start + capacity
        guard limit < units.count else { return units.count }
        var candidate = limit
        while candidate > start + capacity / 3, units[candidate - 1] != 0x20 { candidate -= 1 }
        return candidate > start + capacity / 3 ? candidate : limit
    }

    /// The x position where visual line `lineIndex` of a laid-out row starts.
    func originX(ofLine lineIndex: Int, in layout: CodeLineLayout) -> CGFloat {
        codeX + (lineIndex == 0 ? 0 : layout.continuationIndent)
    }

    /// The UTF-16 offset nearest to `x` within visual line `lineIndex` of a laid-out row.
    func offset(atX x: CGFloat, line lineIndex: Int, in layout: CodeLineLayout, text: String) -> Int {
        let index = min(max(0, lineIndex), layout.lines.count - 1)
        let range = layout.lines[index]
        let localX = x - originX(ofLine: index, in: layout)
        if layout.isPlainASCII {
            let column = Int((localX / characterWidth).rounded())
            return range.location + min(max(0, column), range.length)
        }
        let line = ctLine(for: text, range: range)
        let offset = CTLineGetStringIndexForPosition(line, CGPoint(x: localX, y: 0))
        return offset == kCFNotFound ? range.location : min(max(range.location, offset), range.location + range.length)
    }

    /// The x position, from the row's leading edge, of a UTF-16 offset within one visual line.
    func x(ofOffset offset: Int, line lineIndex: Int, in layout: CodeLineLayout, text: String) -> CGFloat {
        let range = layout.lines[lineIndex]
        let clamped = min(max(range.location, offset), range.location + range.length)
        let origin = originX(ofLine: lineIndex, in: layout)
        if layout.isPlainASCII {
            return origin + CGFloat(clamped - range.location) * characterWidth
        }
        let line = ctLine(for: text, range: range)
        return origin + CTLineGetOffsetForStringIndex(line, clamped, nil)
    }

    func ctLine(for text: String, range: NSRange, attributes: NSAttributedString? = nil) -> CTLine {
        let string = attributes ?? NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        return CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
    }

    private func measuredLayout(of text: String, width: CGFloat, columns: Int) -> CodeLineLayout {
        let string = NSAttributedString(string: text, attributes: [.font: font])
        let length = string.length
        guard length > 0 else { return CodeLineLayout(lines: [NSRange(location: 0, length: 0)], isPlainASCII: false, continuationIndent: 0) }
        let indent = CGFloat(Self.continuationIndentColumns(Array(text.utf16), columns: columns)) * characterWidth
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var lines: [NSRange] = []
        var start = 0
        var available = width
        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(available))
            if count <= 0 { count = CTTypesetterSuggestClusterBreak(typesetter, start, Double(available)) }
            if count <= 0 { count = 1 }
            lines.append(NSRange(location: start, length: count))
            start += count
            available = width - indent
        }
        return CodeLineLayout(lines: lines, isPlainASCII: false, continuationIndent: lines.count > 1 ? indent : 0)
    }

    private struct LayoutKey: Hashable {
        var text: String
        var width: Int
    }
}

/// Where one code line breaks into visual lines, as UTF-16 ranges.
struct CodeLineLayout: Equatable {
    var lines: [NSRange]
    var isPlainASCII: Bool
    /// How far past the code column the second and later visual lines start.
    var continuationIndent: CGFloat

    func lineIndex(containing offset: Int) -> Int {
        for (index, range) in lines.enumerated() where offset < range.location + range.length {
            return index
        }
        return max(0, lines.count - 1)
    }
}

/// Turns a line of source into the text the pane draws.
///
/// Tabs become spaces up to the next stop of four columns, and control characters become their
/// visible Unicode pictures, so a stray escape code can never change what the pane shows.
enum DisplayText {
    static let tabWidth = 4

    static func make(_ source: String) -> (text: String, isPlainASCII: Bool) {
        var isPlainASCII = true
        var needsWork = false
        for unit in source.utf16 where unit < 0x20 || unit >= 0x7F {
            needsWork = true
            if unit != 0x09 { isPlainASCII = false }
        }
        guard needsWork else { return (source, true) }

        var output = String.UnicodeScalarView()
        var column = 0
        for scalar in source.unicodeScalars {
            switch scalar.value {
            case 0x09:
                let spaces = tabWidth - column % tabWidth
                output.append(contentsOf: repeatElement(" ", count: spaces))
                column += spaces
            case 0x00..<0x20:
                output.append(Unicode.Scalar(0x2400 + scalar.value)!)
                column += 1
            case 0x7F:
                output.append(Unicode.Scalar(0x2421)!)
                column += 1
            default:
                output.append(scalar)
                column += 1
            }
        }
        return (String(output), isPlainASCII)
    }

    /// Maps a UTF-16 offset in the display text back to the source line, so a copy keeps tabs.
    static func sourceOffset(forDisplayOffset target: Int, in source: String) -> Int {
        var displayOffset = 0
        var sourceOffset = 0
        var column = 0
        for scalar in source.unicodeScalars {
            guard displayOffset < target else { break }
            let width: Int
            if scalar.value == 0x09 {
                width = tabWidth - column % tabWidth
            } else if scalar.value < 0x20 || scalar.value == 0x7F {
                width = 1
            } else {
                width = scalar.utf16.count
            }
            displayOffset += width
            column += scalar.value == 0x09 ? width : 1
            sourceOffset += scalar.utf16.count
        }
        return sourceOffset
    }
}
