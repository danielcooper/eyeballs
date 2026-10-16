import AppKit
import SwiftUI

/// The row behind every cell. It draws no selection, because the pane draws its own.
@MainActor
final class DiffRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("row")

    override var isOpaque: Bool { true }

    override var isFloating: Bool {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        (isGroupRowStyle ? DiffColors.fileHeader : DiffColors.paneBackground).setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
}

/// The sticky header at the top of each file: collapse, path, counts and "Comment on file".
@MainActor
final class FileHeaderView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("fileHeader")
    static let height: CGFloat = 40

    weak var pane: DiffPaneController?
    private(set) var content: FileHeaderContent?

    private let chevron = NSButton()
    private let icon = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let changeChip = ChipLabel()
    private let threadsLabel = NSTextField(labelWithString: "")
    private let commentButton = NSButton()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(toggleCollapsed)
        chevron.contentTintColor = .secondaryLabelColor

        icon.imageScaling = .scaleProportionallyDown
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.cell?.truncatesLastVisibleLine = true
        countsLabel.lineBreakMode = .byClipping
        threadsLabel.font = .systemFont(ofSize: 11, weight: .medium)
        threadsLabel.textColor = .secondaryLabelColor

        commentButton.title = "Comment on file"
        commentButton.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        commentButton.imagePosition = .imageLeading
        commentButton.bezelStyle = .accessoryBarAction
        commentButton.controlSize = .small
        commentButton.font = .systemFont(ofSize: 11)
        commentButton.target = self
        commentButton.action = #selector(commentOnFile)
        commentButton.toolTip = "Start a thread about the whole file"

        for view in [chevron, icon, pathLabel, countsLabel, changeChip, threadsLabel, commentButton] as [NSView] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("FileHeaderView is built in code") }

    func show(_ content: FileHeaderContent, pane: DiffPaneController) {
        self.content = content
        self.pane = pane
        chevron.image = NSImage(systemSymbolName: content.isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.setAccessibilityLabel(content.isCollapsed ? "Expand file" : "Collapse file")
        chevron.toolTip = content.isCollapsed ? "Show this file's changes" : "Hide this file's changes"

        let style = FileChangeStyle(content.change)
        icon.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: style.words)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = style.color

        pathLabel.attributedStringValue = Self.pathText(path: content.path, oldPath: content.oldPath)
        countsLabel.attributedStringValue = content.isBinary ? NSAttributedString() : Self.countsText(additions: content.additions, deletions: content.deletions)
        let chipWords = content.isBinary ? (content.change == .modified ? "Binary" : "\(style.words) · Binary") : style.wordsShownInHeader
        changeChip.isHidden = chipWords == nil
        changeChip.show(text: chipWords ?? "", tint: style.color)

        threadsLabel.isHidden = content.threadCount == 0
        threadsLabel.stringValue = content.threadCount == 1 ? "1 thread" : "\(content.threadCount) threads"

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilitySummary(content, style: style))
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        chevron.frame = NSRect(x: 8, y: midY - 10, width: 20, height: 20)
        icon.frame = NSRect(x: 30, y: midY - 8, width: 16, height: 16)

        commentButton.sizeToFit()
        var right = bounds.width - 12
        commentButton.frame = NSRect(x: right - commentButton.frame.width, y: midY - commentButton.frame.height / 2,
                                     width: commentButton.frame.width, height: commentButton.frame.height)
        right = commentButton.frame.minX - 10
        if !threadsLabel.isHidden {
            threadsLabel.sizeToFit()
            threadsLabel.frame.origin = NSPoint(x: right - threadsLabel.frame.width, y: midY - threadsLabel.frame.height / 2)
            right = threadsLabel.frame.minX - 12
        }

        countsLabel.sizeToFit()
        let chipSize = changeChip.isHidden ? .zero : changeChip.fittingSize
        let trailingWidth = countsLabel.frame.width + (chipSize.width > 0 ? chipSize.width + 8 : 0)
        let pathX: CGFloat = 52
        let pathWidth = max(40, min(pathLabel.attributedStringValue.size().width + 4, right - pathX - trailingWidth - 10))
        pathLabel.frame = NSRect(x: pathX, y: midY - 9, width: pathWidth, height: 18)
        countsLabel.frame.origin = NSPoint(x: pathLabel.frame.maxX + 10, y: midY - countsLabel.frame.height / 2)
        if !changeChip.isHidden {
            changeChip.frame = NSRect(x: countsLabel.frame.maxX + 8, y: midY - chipSize.height / 2, width: chipSize.width, height: chipSize.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffColors.fileHeader.setFill()
        bounds.fill()
        DiffColors.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func toggleCollapsed() {
        guard let content else { return }
        pane?.setFile(content.path, collapsed: !content.isCollapsed)
    }

    @objc private func commentOnFile() {
        guard let content else { return }
        pane?.openComposer(.draft(.newThread(.file(path: content.path))))
    }

    private func accessibilitySummary(_ content: FileHeaderContent, style: FileChangeStyle) -> String {
        var parts = [content.path, style.words]
        if let oldPath = content.oldPath { parts.append("from \(oldPath)") }
        if !content.isBinary { parts.append("\(content.additions) added, \(content.deletions) deleted") }
        if content.threadCount > 0 { parts.append(threadsLabel.stringValue) }
        if content.isCollapsed { parts.append("collapsed") }
        return parts.joined(separator: ", ")
    }

    static func pathText(path: String, oldPath: String?) -> NSAttributedString {
        let regular = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let text = NSMutableAttributedString()
        if let oldPath {
            text.append(NSAttributedString(string: oldPath, attributes: [.font: regular, .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(NSAttributedString(string: "  →  ", attributes: [.font: regular, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        let folder = (path as NSString).deletingLastPathComponent
        if !folder.isEmpty {
            text.append(NSAttributedString(string: folder + "/", attributes: [.font: regular, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        text.append(NSAttributedString(string: (path as NSString).lastPathComponent, attributes: [.font: bold, .foregroundColor: NSColor.labelColor]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
    }

    static func countsText(additions: Int, deletions: Int) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let text = NSMutableAttributedString(string: "+\(additions)", attributes: [.font: font, .foregroundColor: DiffColors.addedText])
        text.append(NSAttributedString(string: " −\(deletions)", attributes: [.font: font, .foregroundColor: DiffColors.deletedText]))
        return text
    }
}

/// The words, symbol and colour for a file's change kind. The words always appear with the colour.
struct FileChangeStyle {
    var symbol: String
    var words: String
    var color: NSColor
    /// Modified files are the common case, so their header shows no chip.
    var wordsShownInHeader: String?

    @MainActor
    init(_ change: FileChange) {
        switch change {
        case .added: (symbol, words, color, wordsShownInHeader) = ("plus.square.fill", "Added", DiffColors.addedText, "Added")
        case .deleted: (symbol, words, color, wordsShownInHeader) = ("minus.square.fill", "Deleted", DiffColors.deletedText, "Deleted")
        case .renamed: (symbol, words, color, wordsShownInHeader) = ("arrow.right.square.fill", "Renamed", .systemBlue, "Renamed")
        case .copied: (symbol, words, color, wordsShownInHeader) = ("plus.square.on.square.fill", "Copied", .systemBlue, "Copied")
        case .typeChanged: (symbol, words, color, wordsShownInHeader) = ("t.square.fill", "Type changed", .systemPurple, "Type changed")
        case .modified: (symbol, words, color, wordsShownInHeader) = ("dot.square.fill", "Modified", .systemOrange, nil)
        }
    }
}

/// A small capsule of words, such as "Added" or "Renamed".
@MainActor
final class ChipLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .secondaryLabelColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .labelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("ChipLabel is built in code") }

    func show(text: String, tint: NSColor) {
        label.stringValue = text
        self.tint = tint
        needsDisplay = true
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: ceil(size.width) + 14, height: 18)
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 7, y: (bounds.height - size.height) / 2, width: ceil(size.width), height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        tint.withAlphaComponent(0.14).setFill()
        path.fill()
        tint.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The `@@ -40,6 +40,9 @@ func get(…)` band above each hunk.
@MainActor
final class HunkHeaderView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("hunk")
    static let height: CGFloat = 26

    weak var pane: DiffPaneController?
    private var text = ""

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func show(_ content: HunkHeaderContent, pane: DiffPaneController) {
        text = content.text
        self.pane = pane
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Hunk: \(content.text)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pane else { return }
        let metrics = pane.metrics
        DiffColors.paneBackground.setFill()
        bounds.fill()
        DiffColors.hunkBand.setFill()
        bounds.fill(using: .sourceOver)
        DiffColors.hunkGutter.setFill()
        NSRect(x: 0, y: 0, width: 2 * metrics.numberColumnWidth, height: bounds.height).fill(using: .sourceOver)
        let attributes: [NSAttributedString.Key: Any] = [.font: metrics.font, .foregroundColor: NSColor.secondaryLabelColor]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let truncated = CTLineCreateTruncatedLine(
            line, Double(max(40, bounds.width - metrics.codeX - 16)), .end,
            CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))) ?? line
        drawLine(truncated, at: CGPoint(x: metrics.codeX, y: (bounds.height - metrics.lineHeight) / 2 + metrics.baseline))
    }
}

/// "⋯ 23 unchanged lines" between hunks. A click shows the lines from the file's full text.
@MainActor
final class GapRowView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("gap")
    static let height: CGFloat = 28

    weak var pane: DiffPaneController?
    private var content: GapContent?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func show(_ content: GapContent, pane: DiffPaneController) {
        self.content = content
        self.pane = pane
        setAccessibilityElement(true)
        setAccessibilityRole(content.canExpand ? .button : .staticText)
        setAccessibilityLabel(content.canExpand ? "Show \(label(for: content))" : label(for: content))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func label(for content: GapContent) -> String {
        content.hiddenCount == 1 ? "1 unchanged line" : "\(content.hiddenCount) unchanged lines"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pane, let content else { return }
        let metrics = pane.metrics
        DiffColors.paneBackground.setFill()
        bounds.fill()
        DiffColors.gapBand.setFill()
        bounds.fill(using: .sourceOver)
        DiffColors.gapGutter.setFill()
        NSRect(x: 0, y: 0, width: 2 * metrics.numberColumnWidth, height: bounds.height).fill(using: .sourceOver)

        if content.canExpand,
           let image = NSImage(systemSymbolName: "arrow.up.and.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(.init(paletteColors: [DiffColors.commentButton]))) {
            let size = image.size
            image.draw(in: NSRect(x: metrics.numberColumnWidth - size.width / 2, y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: content.canExpand ? DiffColors.commentButton : NSColor.secondaryLabelColor,
        ]
        let text = content.canExpand ? "⋯  \(label(for: content)) · Show" : "⋯  \(label(for: content))"
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        drawLine(line, at: CGPoint(x: metrics.codeX, y: bounds.height / 2 + 4))
    }

    override func resetCursorRects() {
        if content?.canExpand == true { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let content, content.canExpand else { return super.mouseDown(with: event) }
        pane?.expandGap(GapID(path: content.path, index: content.index))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let content, content.canExpand else { return false }
        pane?.expandGap(GapID(path: content.path, index: content.index))
        return true
    }
}

/// A one-line note in place of a file's lines, such as "Binary file not shown".
@MainActor
final class NoticeRowView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("notice")
    static let height: CGFloat = 36

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    weak var pane: DiffPaneController?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("NoticeRowView is built in code") }

    func show(_ content: NoticeContent, pane: DiffPaneController) {
        self.pane = pane
        icon.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)
        label.stringValue = content.text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let x = pane?.metrics.codeX ?? 108
        icon.frame = NSRect(x: x, y: bounds.midY - 8, width: 16, height: 16)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: icon.frame.maxX + 8, y: bounds.midY - label.frame.height / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffColors.paneBackground.setFill()
        bounds.fill()
    }
}

/// Stands in for a file too big to show at once, with a "Load diff" button.
@MainActor
final class BigFileRowView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("bigFile")
    static let height: CGFloat = 76

    weak var pane: DiffPaneController?
    private var content: BigFileContent?
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Load diff", target: nil, action: nil)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        button.bezelStyle = .push
        button.controlSize = .regular
        button.target = self
        button.action = #selector(load)
        addSubview(label)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("BigFileRowView is built in code") }

    func show(_ content: BigFileContent, pane: DiffPaneController) {
        self.content = content
        self.pane = pane
        label.stringValue = "Large diffs start collapsed. This one has \(content.lineCount) lines: +\(content.additions) −\(content.deletions)."
        button.setAccessibilityLabel("Load diff of \((content.path as NSString).lastPathComponent)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        button.sizeToFit()
        let total = label.frame.height + 8 + button.frame.height
        let top = (bounds.height - total) / 2
        label.frame = NSRect(x: 16, y: top, width: bounds.width - 32, height: label.frame.height)
        button.frame.origin = NSPoint(x: (bounds.width - button.frame.width) / 2, y: label.frame.maxY + 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffColors.paneBackground.setFill()
        bounds.fill()
    }

    @objc private func load() {
        guard let content else { return }
        pane?.loadBigFile(content.path)
    }
}

/// Empty space under the last file, so the end of the diff can scroll up into view.
@MainActor
final class FooterRowView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("footer")
    static let height: CGFloat = 96

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DiffColors.paneBackground.setFill()
        bounds.fill()
    }
}

/// Holds one SwiftUI view in a table row, such as a thread card or the layer overview.
@MainActor
final class HostingRowView<Content: View>: NSView {
    let host: NSHostingView<Content>

    init(identifier: NSUserInterfaceItemIdentifier, rootView: Content) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        self.identifier = identifier
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("HostingRowView is built in code") }

    override func layout() {
        super.layout()
        host.frame = bounds
    }
}

@MainActor
func drawLine(_ line: CTLine, at origin: CGPoint) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = origin
    CTLineDraw(line, context)
    context.restoreGState()
}
