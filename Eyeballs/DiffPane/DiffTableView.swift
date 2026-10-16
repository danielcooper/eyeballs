import AppKit

/// The diff table. It passes mouse and keyboard input to its pane controller.
///
/// Single-letter shortcuts act only while the table itself holds keyboard focus, so typing in a
/// composer can never resolve a thread or jump away.
@MainActor
final class DiffTableView: NSTableView {
    weak var pane: DiffPaneController?
    private var hoverArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, let pane,
              flags.isDisjoint(with: [.command, .control, .option]),
              let characters = event.characters, characters.count == 1, let character = characters.first,
              pane.handleShortcut(character) else {
            super.keyDown(with: event)
            return
        }
    }

    override func cancelOperation(_ sender: Any?) {
        pane?.clearSelections()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        pane?.redrawVisibleCodeRows()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        pane?.redrawVisibleCodeRows()
        return resigned
    }

    // MARK: Width

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !inLiveResize { pane?.widthDidChange() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        pane?.widthDidChange()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        let handled = pane?.mouseDown(at: point, extending: event.modifierFlags.contains(.shift), clickCount: event.clickCount) ?? false
        if !handled { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pane, pane.isDragging else { return super.mouseDragged(with: event) }
        autoscroll(with: event)
        pane.mouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard let pane, pane.isDragging else { return super.mouseUp(with: event) }
        pane.mouseUp()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pane?.hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pane?.hover(at: nil)
    }

    // MARK: Copy

    @objc func copy(_ sender: Any?) {
        pane?.copySelection(to: .general)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return pane?.hasCopyableSelection ?? false }
        return super.validateUserInterfaceItem(item)
    }
}
