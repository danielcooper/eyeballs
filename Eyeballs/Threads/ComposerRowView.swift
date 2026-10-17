import AppKit
import SwiftUI

/// Shared sizes for thread cards and composers, so both line up in the pane.
enum ThreadLayout {
    static let maxCardWidth: CGFloat = 880
    static let trailingMargin: CGFloat = 16
    static let rowMargin: CGFloat = 6

    static func cardWidth(rowWidth: CGFloat, leadingInset: CGFloat) -> CGFloat {
        max(200, min(maxCardWidth, rowWidth - leadingInset - trailingMargin))
    }
}

/// The comment box under a line, a file, the layer, or a thread.
///
/// Its text always comes from, and goes straight back to, the pane's draft store keyed by
/// `ComposerKey`. A recycled row therefore never shows one composer's draft under another.
///
/// The buttons always run Cancel, Send now, then the blue primary button, and the blue button is
/// always what ⌘↩ does. Preview, or ⇧⌘P, shows the text as the thread will show it.
@MainActor
final class ComposerRowView: NSView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("composer")
    static let minimumTextHeight: CGFloat = 66
    static let textInset = NSSize(width: 6, height: 7)
    static let textFont = NSFont.systemFont(ofSize: 13)
    static let sendNowTitle = "Send now"

    weak var pane: DiffPaneController?
    private(set) var content: ComposerRowContent?
    let textView = ComposerTextView()
    /// Typing undo stays with this composer. In the window's undo manager it would outlive the
    /// row, and a recycled row could then undo into another composer's text.
    private let typingUndo = UndoManager()
    private let titleLabel = NSTextField(labelWithString: "")
    private let modePicker = NSSegmentedControl(labels: ["Write", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
    private let preview = PreviewHostingView(rootView: ComposerPreview(text: ""))
    private let hintLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let sendNowButton = NSButton(title: ComposerRowView.sendNowTitle, target: nil, action: nil)
    private let submitButton = NSButton(title: "Add to review", target: nil, action: nil)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// The row itself holds keyboard focus while it previews, so its keys keep working.
    override var acceptsFirstResponder: Bool { content?.isPreviewing == true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byClipping

        modePicker.controlSize = .small
        modePicker.font = .systemFont(ofSize: 11)
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        modePicker.toolTip = "Write the comment, or preview its Markdown (⇧⌘P)"
        modePicker.setAccessibilityLabel("Write or preview")
        preview.sizingOptions = []
        preview.setAccessibilityLabel("Preview")

        textView.font = Self.textFont
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = Self.textInset
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.delegate = self
        textView.setAccessibilityLabel("Comment")
        textView.onCommand = { [weak self] command in self?.perform(command) }
        textView.onFocusChange = { [weak self] in self?.needsDisplay = true }

        cancelButton.bezelStyle = .push
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.toolTip = "Discard this comment. Edit > Undo brings it back. Esc closes it and keeps the draft."
        sendNowButton.bezelStyle = .push
        sendNowButton.target = self
        sendNowButton.action = #selector(sendNowPressed)
        sendNowButton.toolTip = "Send to the agent at once, without waiting for the review (⌥⌘↩)"
        submitButton.bezelStyle = .push
        submitButton.target = self
        submitButton.action = #selector(submitPressed)
        submitButton.bezelColor = .controlAccentColor
        if #available(macOS 26.0, *) { submitButton.tintProminence = .primary }

        for view in [titleLabel, modePicker, hintLabel, textView, preview, cancelButton, sendNowButton, submitButton] as [NSView] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("ComposerRowView is built in code") }

    func show(_ content: ComposerRowContent, text: String, pane: DiffPaneController) {
        if self.content?.key != content.key { typingUndo.removeAllActions() }
        self.content = content
        self.pane = pane
        titleLabel.stringValue = content.title
        submitButton.title = content.submitTitle
        submitButton.toolTip = content.canSendNow ? "Add to your pending review (⌘↩)" : "Save the comment (⌘↩)"
        sendNowButton.isHidden = !content.canSendNow
        modePicker.selectedSegment = content.isPreviewing ? 1 : 0
        textView.isHidden = content.isPreviewing
        preview.isHidden = !content.isPreviewing
        if content.isPreviewing { preview.rootView = ComposerPreview(text: text) }
        textView.placeholder = content.canSendNow ? "Leave a comment" : "Edit the comment."
        if textView.string != text { textView.string = text }
        needsLayout = true
        needsDisplay = true
    }

    /// The buttons' titles from left to right, and the title of the blue one, for the self-test.
    var buttonTitlesInOrder: [String] {
        [cancelButton, sendNowButton, submitButton].filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }.map(\.title)
    }

    var primaryButtonTitle: String { submitButton.title }

    // MARK: Geometry

    static func height(forText text: String, rowWidth: CGFloat, content: ComposerRowContent) -> CGFloat {
        let boxWidth = ThreadLayout.cardWidth(rowWidth: rowWidth, leadingInset: content.leadingInset)
        let textHeight = content.isPreviewing
            ? previewHeight(for: text, width: boxWidth - 24)
            : textAreaHeight(for: text, width: boxWidth - 24)
        return topMargin(content) + 34 + textHeight + 12 + 26 + 12 + ThreadLayout.rowMargin
    }

    private static func topMargin(_ content: ComposerRowContent) -> CGFloat {
        content.attachedToCard ? 0 : ThreadLayout.rowMargin
    }

    private static let measuringStorage = NSTextStorage()
    private static let measuringManager: NSLayoutManager = {
        let manager = NSLayoutManager()
        measuringStorage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = NSTextContainer().lineFragmentPadding
        manager.addTextContainer(container)
        return manager
    }()

    static func textAreaHeight(for text: String, width: CGFloat) -> CGFloat {
        let manager = measuringManager
        guard let container = manager.textContainers.first else { return minimumTextHeight }
        container.size = NSSize(width: max(40, width - 2 * textInset.width), height: .greatestFiniteMagnitude)
        let measured = text.isEmpty ? " " : (text.hasSuffix("\n") ? text + " " : text)
        measuringStorage.setAttributedString(NSAttributedString(string: measured, attributes: [.font: textFont]))
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        return max(minimumTextHeight, ceil(used + 2 * textInset.height))
    }

    private static let previewMeasurer = NSHostingController(rootView: ComposerPreview(text: "", fillsHeight: false))

    static func previewHeight(for text: String, width: CGFloat) -> CGFloat {
        previewMeasurer.rootView = ComposerPreview(text: text, fillsHeight: false)
        let size = previewMeasurer.sizeThatFits(in: CGSize(width: max(40, width), height: .greatestFiniteMagnitude))
        return max(minimumTextHeight, ceil(size.height))
    }

    private var boxRect: NSRect {
        guard let content else { return bounds }
        let width = ThreadLayout.cardWidth(rowWidth: bounds.width, leadingInset: content.leadingInset)
        let top = Self.topMargin(content)
        return NSRect(x: content.leadingInset, y: top, width: width, height: bounds.height - top - ThreadLayout.rowMargin)
    }

    private var textAreaRect: NSRect {
        let box = boxRect
        let top = box.minY + 34
        let buttonsTop = box.maxY - 12 - 26
        return NSRect(x: box.minX + 12, y: top, width: box.width - 24, height: max(Self.minimumTextHeight, buttonsTop - 12 - top))
    }

    override func layout() {
        super.layout()
        let box = boxRect
        modePicker.sizeToFit()
        modePicker.frame.origin = NSPoint(x: box.maxX - 12 - modePicker.frame.width, y: box.minY + 17 - modePicker.frame.height / 2)
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(x: box.minX + 12, y: box.minY + 10, width: max(0, min(titleLabel.frame.width, modePicker.frame.minX - 8 - box.minX - 12)),
                                  height: titleLabel.frame.height)
        textView.frame = textAreaRect
        preview.frame = textAreaRect

        let buttonsY = box.maxY - 12 - 26
        var right = box.maxX - 12
        for button in [submitButton, sendNowButton, cancelButton] where !button.isHidden {
            button.sizeToFit()
            let width = max(button.frame.width, 72)
            button.frame = NSRect(x: right - width, y: buttonsY, width: width, height: 26)
            right = button.frame.minX - 8
        }
        let hintWidth = max(0, right - (box.minX + 12) - 8)
        hintLabel.stringValue = content.map { Self.hint(for: $0, fitting: hintWidth, font: hintLabel.font) } ?? ""
        hintLabel.isHidden = hintLabel.stringValue.isEmpty
        hintLabel.sizeToFit()
        hintLabel.frame = NSRect(x: box.minX + 12, y: buttonsY + (26 - hintLabel.frame.height) / 2, width: hintWidth, height: hintLabel.frame.height)
    }

    /// As many whole hints as fit, dropping them from the end. A hint is never cut off mid-word.
    static func hint(for content: ComposerRowContent, fitting width: CGFloat, font: NSFont?) -> String {
        var hints = ["⌘↩ \(content.submitTitle)"]
        if content.canSendNow { hints.append("⌥⌘↩ \(sendNowTitle)") }
        hints.append("Esc closes")
        hints.append(content.isPreviewing ? "⇧⌘P goes back to writing" : "⇧⌘P previews the Markdown")
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 11)]
        for count in stride(from: hints.count, through: 1, by: -1) {
            let text = hints.prefix(count).joined(separator: "  ·  ")
            if (text as NSString).size(withAttributes: attributes).width <= width { return text }
        }
        return ""
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffColors.paneBackground.setFill()
        bounds.fill()
        guard let content else { return }
        let box = boxRect.insetBy(dx: 0.5, dy: 0)
        let radius: CGFloat = 8
        let shape: NSBezierPath
        if content.attachedToCard {
            shape = Self.bottomRoundedPath(box, radius: radius)
            DiffColors.cardHeader.setFill()
        } else {
            shape = NSBezierPath(roundedRect: box.insetBy(dx: 0, dy: 0.5), xRadius: radius, yRadius: radius)
            DiffColors.cardBackground.setFill()
        }
        shape.fill()
        DiffColors.border.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let field = textAreaRect.insetBy(dx: -0.5, dy: -0.5)
        let fieldPath = NSBezierPath(roundedRect: field, xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill()
        fieldPath.fill()
        let isFocused = window?.firstResponder === textView || window?.firstResponder === self
        (isFocused ? NSColor.controlAccentColor : DiffColors.border).setStroke()
        fieldPath.lineWidth = isFocused ? 2 : 1
        fieldPath.stroke()
    }

    private static func bottomRoundedPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        return path
    }

    // MARK: Keys and focus

    override func keyDown(with event: NSEvent) {
        if let command = ComposerCommand(event) { return perform(command) }
        super.keyDown(with: event)
    }

    /// Catches ⇧⌘P before any menu item does, while this composer has keyboard focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard ComposerCommand(event) == .togglePreview, let responder = window?.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self) else { return super.performKeyEquivalent(with: event) }
        perform(.togglePreview)
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        perform(.close)
    }

    override func mouseDown(with event: NSEvent) {
        if content?.isPreviewing == true { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // MARK: Actions

    func undoManager(for view: NSTextView) -> UndoManager? {
        typingUndo
    }

    func textDidChange(_ notification: Notification) {
        guard let key = content?.key else { return }
        pane?.composerTextDidChange(textView.string, for: key)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let key = content?.key else { return }
        pane?.flushDraft(for: key)
    }

    @objc private func cancelPressed() {
        guard let key = content?.key else { return }
        pane?.discardComposer(key)
    }
    @objc private func sendNowPressed() { perform(.sendNow) }
    @objc private func submitPressed() { perform(.submit) }

    @objc private func modeChanged() {
        guard let content, (modePicker.selectedSegment == 1) != content.isPreviewing else { return }
        perform(.togglePreview)
    }

    private func perform(_ command: ComposerCommand) {
        guard let content else { return }
        switch command {
        case .submit: pane?.submitComposer(content.key, sendNow: false)
        case .sendNow: pane?.submitComposer(content.key, sendNow: content.canSendNow)
        case .togglePreview: pane?.setComposer(content.key, previewing: !content.isPreviewing)
        case .close: pane?.closeComposer(content.key)
        }
    }
}

/// What a key in a composer asks for: ⌘↩ adds to the review, ⌥⌘↩ sends now, ⇧⌘P switches
/// between writing and preview, and Esc closes the box.
enum ComposerCommand: Equatable {
    case submit, sendNow, togglePreview, close

    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, flags.contains(.command) {
            self = flags.contains(.option) ? .sendNow : .submit
        } else if flags.intersection([.command, .shift, .option, .control]) == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "p" {
            self = .togglePreview
        } else {
            return nil
        }
    }
}

/// The composer's text view. It hands the composer's own keys to the row, and Esc closes the box.
@MainActor
final class ComposerTextView: NSTextView {
    var onCommand: ((ComposerCommand) -> Void)?
    var onFocusChange: (() -> Void)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        if let command = ComposerCommand(event) {
            onCommand?(command)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCommand?(.close)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        onFocusChange?()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        onFocusChange?()
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: font ?? ComposerRowView.textFont, .foregroundColor: NSColor.placeholderTextColor])
    }
}

/// The comment as the thread will show it, set where the text view's text sits.
struct ComposerPreview: View {
    let text: String
    /// True in the composer, where the preview fills the text area from the top. False to measure it.
    var fillsHeight = true

    var body: some View {
        Group {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Nothing to preview yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownText(text)
            }
        }
        .padding(.horizontal, ComposerRowView.textInset.width + 5)
        .padding(.vertical, ComposerRowView.textInset.height)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
    }
}

/// Shows the preview without taking clicks, so a click in it focuses the composer instead.
@MainActor
final class PreviewHostingView: NSHostingView<ComposerPreview> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
