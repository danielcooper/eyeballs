import AppKit
import SwiftUI

/// The bar above the diff that finds text in the layer's code.
///
/// ⌘F opens it. Return and ⇧Return, like ⌘G and ⇧⌘G, move through the matches. Esc or Done
/// closes it.
struct FindBar: View {
    let windowState: ReviewWindowState

    private var pane: DiffPaneController? { windowState.pane }

    var body: some View {
        HStack(spacing: 8) {
            FindField(windowState: windowState, text: windowState.findText)
                .frame(minWidth: 180, maxWidth: 320)
            Text(summary)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            ControlGroup {
                Button { pane?.moveFindMatch(by: -1) } label: {
                    Label("Previous match", systemImage: "chevron.up")
                }
                .help("Previous match (⇧⌘G)")
                Button { pane?.moveFindMatch(by: 1) } label: {
                    Label("Next match", systemImage: "chevron.down")
                }
                .help("Next match (⌘G)")
            }
            .fixedSize()
            .disabled(windowState.findStatus.count == 0)
            Spacer(minLength: 0)
            Button("Done") { pane?.closeFind() }
                .help("Close the find bar (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var summary: String {
        let status = windowState.findStatus
        guard !windowState.findText.isEmpty else { return "" }
        guard status.count > 0 else { return "No matches" }
        guard let current = status.current else { return status.count == 1 ? "1 match" : "\(status.count) matches" }
        return "\(current + 1) of \(status.count)"
    }
}

/// The find bar's search field. It is AppKit's own, so the bar gets Return, ⇧Return and Esc
/// before the field acts on them.
struct FindField: NSViewRepresentable {
    let windowState: ReviewWindowState
    /// Passed in so the field shows text that ⌘E put there.
    let text: String

    func makeNSView(context: Context) -> FindSearchField {
        let field = FindSearchField()
        field.windowState = windowState
        field.placeholderString = "Find in this layer"
        field.setAccessibilityLabel("Find in this layer")
        field.sendsSearchStringImmediately = true
        field.stringValue = text
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.textChanged(_:))
        return field
    }

    func updateNSView(_ field: FindSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(windowState: windowState) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let windowState: ReviewWindowState

        init(windowState: ReviewWindowState) {
            self.windowState = windowState
        }

        @objc func textChanged(_ field: NSSearchField) {
            windowState.pane?.findTextDidChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                windowState.pane?.moveFindMatch(by: backwards ? -1 : 1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                windowState.pane?.closeFind()
                return true
            default:
                return false
            }
        }
    }
}

final class FindSearchField: NSSearchField {
    weak var windowState: ReviewWindowState?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { windowState?.findFieldDidAppear(self) }
    }

    /// Puts the cursor in the field with its text selected, so typing replaces it.
    func focus() {
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
}
