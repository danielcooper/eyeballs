import AppKit
import CoreText

/// One line of the diff: two line-number columns, a +/− marker and the code, drawn with CoreText.
///
/// The row asks the pane for anything that changes without a rebuild, such as the line
/// selection, the text selection and whether the pointer is over it.
@MainActor
final class CodeRowView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("code")

    weak var pane: DiffPaneController?
    private(set) var content: CodeRowContent?
    private var rowID: RowID?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func show(_ content: CodeRowContent, pane: DiffPaneController) {
        self.content = content
        self.pane = pane
        rowID = .line(content.path, content.line.oldNumber, content.line.newNumber)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let pane, let content, let rowID else { return }
        let metrics = pane.metrics
        let rowWidth = pane.rowWidth
        let layout = metrics.layout(of: content.displayText, isPlainASCII: content.isPlainASCII, rowWidth: rowWidth)
        let isSelectedLine = pane.isLineSelected(rowID)

        drawBackgrounds(content: content, metrics: metrics, isSelectedLine: isSelectedLine)
        if let changed = content.changedRange, changed.length > 0 {
            let color = content.line.kind == .added ? DiffColors.addedWord : DiffColors.deletedWord
            fill(range: changed, in: layout, text: content.displayText, metrics: metrics, color: color, rounded: true)
        }
        if let selected = pane.selectedCharacters(in: rowID), selected.length > 0 {
            let color = pane.isTableFocused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
            fill(range: selected, in: layout, text: content.displayText, metrics: metrics, color: color, rounded: false)
        }
        drawNumbers(content: content, metrics: metrics, isSelectedLine: isSelectedLine)
        drawCode(content: content, layout: layout, metrics: metrics, tokens: pane.tokens(for: content))
        if pane.hoveredRowID == rowID, content.commentLine != nil {
            drawCommentButton(metrics: metrics)
        }
    }

    private func drawBackgrounds(content: CodeRowContent, metrics: CodeMetrics, isSelectedLine: Bool) {
        let line: NSColor
        let gutter: NSColor
        switch content.line.kind {
        case .context: (line, gutter) = (DiffColors.paneBackground, DiffColors.paneBackground)
        case .added: (line, gutter) = (DiffColors.addedLine, DiffColors.addedGutter)
        case .deleted: (line, gutter) = (DiffColors.deletedLine, DiffColors.deletedGutter)
        }
        DiffColors.paneBackground.setFill()
        bounds.fill()
        line.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height).fill(using: .sourceOver)
        gutter.setFill()
        NSRect(x: 0, y: 0, width: 2 * metrics.numberColumnWidth, height: bounds.height).fill(using: .sourceOver)
        if isSelectedLine {
            DiffColors.selectedLine.setFill()
            NSRect(x: 2 * metrics.numberColumnWidth, y: 0, width: bounds.width, height: bounds.height).fill(using: .sourceOver)
            DiffColors.selectedGutter.setFill()
            NSRect(x: 0, y: 0, width: 2 * metrics.numberColumnWidth, height: bounds.height).fill(using: .sourceOver)
        }
    }

    private func drawNumbers(content: CodeRowContent, metrics: CodeMetrics, isSelectedLine: Bool) {
        let color = content.line.kind == .context && !isSelectedLine ? DiffColors.lineNumber : DiffColors.code
        let attributes: [NSAttributedString.Key: Any] = [.font: metrics.font, .foregroundColor: color]
        let width = metrics.numberColumnWidth
        if let old = content.line.oldNumber {
            drawRightAligned(String(old), right: width - 10, attributes: attributes, metrics: metrics)
        }
        if let new = content.line.newNumber {
            drawRightAligned(String(new), right: 2 * width - 10, attributes: attributes, metrics: metrics)
        }
        let marker: String
        let markerColor: NSColor
        switch content.line.kind {
        case .context: return
        case .added: (marker, markerColor) = ("+", DiffColors.addedText)
        case .deleted: (marker, markerColor) = ("−", DiffColors.deletedText)
        }
        let markerLine = CTLineCreateWithAttributedString(NSAttributedString(string: marker, attributes: [.font: metrics.font, .foregroundColor: markerColor]))
        let markerWidth = CTLineGetTypographicBounds(markerLine, nil, nil, nil)
        drawLine(markerLine, at: CGPoint(x: 2 * width + (metrics.markerWidth - markerWidth) / 2, y: metrics.baseline))
    }

    private func drawCode(content: CodeRowContent, layout: CodeLineLayout, metrics: CodeMetrics, tokens: [SyntaxToken]) {
        let text = NSMutableAttributedString(string: content.displayText, attributes: [.font: metrics.font, .foregroundColor: DiffColors.code])
        for token in tokens where NSMaxRange(token.range) <= text.length {
            text.addAttribute(.foregroundColor, value: Self.color(for: token.kind), range: token.range)
        }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        for (index, range) in layout.lines.enumerated() where range.length > 0 {
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
            drawLine(line, at: CGPoint(x: metrics.originX(ofLine: index, in: layout), y: CGFloat(index) * metrics.lineHeight + metrics.baseline))
        }
    }

    private func drawCommentButton(metrics: CodeMetrics) {
        let rect = commentButtonRect(metrics: metrics)
        DiffColors.commentButton.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    func commentButtonRect(metrics: CodeMetrics) -> NSRect {
        NSRect(x: 2 * metrics.numberColumnWidth + 1, y: 1, width: 18, height: metrics.lineHeight - 2)
    }

    private func fill(range: NSRange, in layout: CodeLineLayout, text: String, metrics: CodeMetrics, color: NSColor, rounded: Bool) {
        color.setFill()
        for (index, line) in layout.lines.enumerated() {
            let start = max(range.location, line.location)
            let end = min(NSMaxRange(range), NSMaxRange(line))
            guard end > start || (range.length == 0 && start == end) else { continue }
            let x0 = metrics.x(ofOffset: start, line: index, in: layout, text: text)
            let x1 = metrics.x(ofOffset: end, line: index, in: layout, text: text)
            let rect = NSRect(x: x0, y: CGFloat(index) * metrics.lineHeight, width: max(1, x1 - x0), height: metrics.lineHeight)
            if rounded {
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 2, yRadius: 2).fill()
            } else {
                rect.fill()
            }
        }
    }

    private func drawRightAligned(_ string: String, right: CGFloat, attributes: [NSAttributedString.Key: Any], metrics: CodeMetrics) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        drawLine(line, at: CGPoint(x: right - width, y: metrics.baseline))
    }

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: DiffColors.keyword
        case .string: DiffColors.string
        case .comment: DiffColors.comment
        case .number: DiffColors.constant
        case .type: DiffColors.type
        case .function: DiffColors.function
        case .key: DiffColors.key
        case .variable: DiffColors.constant
        }
    }

    // MARK: Pointer and accessibility

    override func resetCursorRects() {
        guard let pane else { return }
        let numbers = 2 * pane.metrics.numberColumnWidth + pane.metrics.markerWidth
        addCursorRect(NSRect(x: 0, y: 0, width: numbers, height: bounds.height), cursor: .pointingHand)
        addCursorRect(NSRect(x: numbers, y: 0, width: max(0, bounds.width - numbers), height: bounds.height), cursor: .iBeam)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityLabel() -> String? {
        guard let content else { return nil }
        let line = content.line
        let code = line.text.trimmingCharacters(in: .whitespaces)
        let spoken = code.isEmpty ? "blank" : code
        switch line.kind {
        case .added: return "Line \(line.newNumber ?? 0), added: \(spoken)"
        case .deleted: return "Old line \(line.oldNumber ?? 0), deleted: \(spoken)"
        case .context: return "Line \(line.newNumber ?? line.oldNumber ?? 0): \(spoken)"
        }
    }
}
