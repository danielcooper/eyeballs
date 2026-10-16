import AppKit

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
@MainActor
final class ComposerRowView: NSView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("composer")
    static let minimumTextHeight: CGFloat = 66
    static let textInset = NSSize(width: 6, height: 7)
    static let textFont = NSFont.systemFont(ofSize: 13)

    weak var pane: DiffPaneController?
    private(set) var content: ComposerRowContent?
    let textView = ComposerTextView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "Markdown works: `code`, **bold**, lists and links.")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let sendNowButton = NSButton(title: "Comment now", target: nil, action: nil)
    private let submitButton = NSButton(title: "Add to review", target: nil, action: nil)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

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
        textView.onSubmit = { [weak self] sendNow in self?.submit(sendNow: sendNow) }
        textView.onCancel = { [weak self] in self?.cancel() }
        textView.onFocusChange = { [weak self] in self?.needsDisplay = true }

        cancelButton.bezelStyle = .push
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.toolTip = "Close and keep the draft (Esc)"
        sendNowButton.bezelStyle = .push
        sendNowButton.target = self
        sendNowButton.action = #selector(sendNowPressed)
        sendNowButton.toolTip = "Send to the agent at once, without waiting for the review (⌥⌘↩)"
        submitButton.bezelStyle = .push
        submitButton.bezelColor = .controlAccentColor
        if #available(macOS 26.0, *) { submitButton.tintProminence = .primary }
        submitButton.target = self
        submitButton.action = #selector(submitPressed)
        submitButton.toolTip = "Add to your pending review (⌘↩)"

        for view in [titleLabel, hintLabel, textView, cancelButton, sendNowButton, submitButton] as [NSView] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("ComposerRowView is built in code") }

    func show(_ content: ComposerRowContent, text: String, pane: DiffPaneController) {
        self.content = content
        self.pane = pane
        titleLabel.stringValue = content.title
        submitButton.title = content.submitTitle
        submitButton.toolTip = content.sendNowTitle == nil ? "Save the comment (⌘↩)" : "Add to your pending review (⌘↩)"
        sendNowButton.isHidden = content.sendNowTitle == nil
        sendNowButton.title = content.sendNowTitle ?? ""
        textView.placeholder = content.sendNowTitle == nil ? "Edit the comment." : "Leave a comment"
        if textView.string != text { textView.string = text }
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Geometry

    static func height(forText text: String, rowWidth: CGFloat, content: ComposerRowContent) -> CGFloat {
        let boxWidth = ThreadLayout.cardWidth(rowWidth: rowWidth, leadingInset: content.leadingInset)
        let textHeight = textAreaHeight(for: text, width: boxWidth - 24)
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

    private var boxRect: NSRect {
        guard let content else { return bounds }
        let width = ThreadLayout.cardWidth(rowWidth: bounds.width, leadingInset: content.leadingInset)
        let top = Self.topMargin(content)
        return NSRect(x: content.leadingInset, y: top, width: width, height: bounds.height - top - ThreadLayout.rowMargin)
    }

    override func layout() {
        super.layout()
        let box = boxRect
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: box.minX + 12, y: box.minY + 10)
        let buttonsY = box.maxY - 12 - 26
        let textTop = box.minY + 34
        textView.frame = NSRect(x: box.minX + 12, y: textTop, width: box.width - 24, height: max(Self.minimumTextHeight, buttonsY - 12 - textTop))

        var right = box.maxX - 12
        for button in [submitButton, sendNowButton, cancelButton] where !button.isHidden {
            button.sizeToFit()
            let width = max(button.frame.width, 72)
            button.frame = NSRect(x: right - width, y: buttonsY, width: width, height: 26)
            right = button.frame.minX - 8
        }
        hintLabel.sizeToFit()
        let hintWidth = max(0, right - (box.minX + 12) - 8)
        hintLabel.isHidden = hintWidth < 120
        hintLabel.frame = NSRect(x: box.minX + 12, y: buttonsY + (26 - hintLabel.frame.height) / 2, width: hintWidth, height: hintLabel.frame.height)
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

        let field = textView.frame.insetBy(dx: -0.5, dy: -0.5)
        let fieldPath = NSBezierPath(roundedRect: field, xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill()
        fieldPath.fill()
        let isFocused = window?.firstResponder === textView
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

    // MARK: Actions

    func textDidChange(_ notification: Notification) {
        guard let key = content?.key else { return }
        pane?.composerTextDidChange(textView.string, for: key)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let key = content?.key else { return }
        pane?.flushDraft(for: key)
    }

    @objc private func cancelPressed() { cancel() }
    @objc private func sendNowPressed() { submit(sendNow: true) }
    @objc private func submitPressed() { submit(sendNow: false) }

    private func submit(sendNow: Bool) {
        guard let content else { return }
        pane?.submitComposer(content.key, sendNow: sendNow && content.sendNowTitle != nil)
    }

    private func cancel() {
        guard let key = content?.key else { return }
        pane?.closeComposer(key)
    }
}

/// The composer's text view: ⌘↩ adds the comment, ⌥⌘↩ sends it now, and Esc closes the box.
@MainActor
final class ComposerTextView: NSTextView {
    var onSubmit: ((_ sendNow: Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onFocusChange: (() -> Void)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, flags.contains(.command) {
            onSubmit?(flags.contains(.option))
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
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
