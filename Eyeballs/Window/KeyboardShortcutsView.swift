import SwiftUI

/// Help > Keyboard Shortcuts: every key the review window knows, in one table.
struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"

    struct Shortcut: Identifiable {
        var keys: String
        var action: String
        var id: String { keys + action }
    }

    struct Group: Identifiable {
        var title: String
        var note: String?
        var shortcuts: [Shortcut]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "In the diff", note: "These letters work while the diff has focus. Click the code first.", shortcuts: [
            Shortcut(keys: "j  or  ↓", action: "Next line"),
            Shortcut(keys: "k  or  ↑", action: "Previous line"),
            Shortcut(keys: "⇧J  ⇧K", action: "Extend the line selection"),
            Shortcut(keys: "n  /  p", action: "Next or previous thread"),
            Shortcut(keys: "a", action: "Next thread that needs you, on any layer"),
            Shortcut(keys: "]  /  [", action: "Next or previous file"),
            Shortcut(keys: "c", action: "Comment on the selected lines"),
            Shortcut(keys: "r", action: "Reply in the focused thread"),
            Shortcut(keys: "e", action: "Resolve or reopen the focused thread"),
            Shortcut(keys: "v", action: "Mark the file viewed"),
            Shortcut(keys: "Esc", action: "Clear the selection"),
        ]),
        Group(title: "From anywhere", note: nil, shortcuts: [
            Shortcut(keys: "⌘]  /  ⌘[", action: "Next or previous file"),
            Shortcut(keys: "⌥⌘]  /  ⌥⌘[", action: "Next or previous thread"),
            Shortcut(keys: "⇧⌘A", action: "Next thread that needs you"),
            Shortcut(keys: "⇧⌘]  /  ⇧⌘[", action: "Layer above or below"),
            Shortcut(keys: "⌘1 to ⌘9", action: "Go to layer 1 to 9"),
            Shortcut(keys: "⇧⌘↩", action: "Finish review"),
            Shortcut(keys: "⌘C", action: "Copy the selected code"),
        ]),
        Group(title: "In a comment box", note: nil, shortcuts: [
            Shortcut(keys: "⌘↩", action: "Add to review"),
            Shortcut(keys: "⌥⌘↩", action: "Send now"),
            Shortcut(keys: "⇧⌘P", action: "Preview the Markdown, or go back to writing"),
            Shortcut(keys: "Esc", action: "Close and keep the draft"),
        ]),
        Group(title: "In Finish review", note: nil, shortcuts: [
            Shortcut(keys: "⌘↩", action: "Submit review"),
            Shortcut(keys: "Esc", action: "Close and keep the summary"),
        ]),
    ]

    var body: some View {
        ScrollView {
            KeyboardShortcutsTable()
        }
        .frame(width: 440, height: 600)
    }
}

/// The groups of shortcuts, laid out as a table, without the window's scroll view.
struct KeyboardShortcutsTable: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(KeyboardShortcutsView.groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.headline)
                    if let note = group.note {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        ForEach(group.shortcuts) { shortcut in
                            GridRow {
                                Text(shortcut.keys)
                                    .font(.body.monospaced())
                                    .frame(minWidth: 120, alignment: .leading)
                                Text(shortcut.action)
                                    .font(.body)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
