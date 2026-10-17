import SwiftUI

/// Help > Keyboard Shortcuts: every key the review window knows, in one table.
struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"
    static let title = "Keyboard Shortcuts"

    struct Shortcut: Identifiable {
        /// Keys that do the same thing, such as `j` and `↓`, or the two ends of a range.
        var keys: [String]
        var action: String
        /// The word between the keys: "or", or "to" for a range such as ⌘1 to ⌘9.
        var joiner = "or"
        var id: String { keys.joined() + action }
    }

    struct Group: Identifiable {
        var title: String
        var note: String?
        var shortcuts: [Shortcut]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "In the diff", note: "These letters work while the diff has focus. Click the code first.", shortcuts: [
            Shortcut(keys: ["j", "↓"], action: "Next line"),
            Shortcut(keys: ["k", "↑"], action: "Previous line"),
            Shortcut(keys: ["⇧J", "⇧K"], action: "Extend the line selection down or up"),
            Shortcut(keys: ["n", "p"], action: "Next or previous thread"),
            Shortcut(keys: ["a"], action: "Next thread that needs you, on any layer"),
            Shortcut(keys: ["]", "["], action: "Next or previous file"),
            Shortcut(keys: ["c"], action: "Comment on the selected lines"),
            Shortcut(keys: ["r"], action: "Reply in the focused thread"),
            Shortcut(keys: ["e"], action: "Resolve or reopen the focused thread"),
            Shortcut(keys: ["v"], action: "Mark the file viewed"),
            Shortcut(keys: ["Esc"], action: "Clear the selection"),
        ]),
        Group(title: "From anywhere", note: nil, shortcuts: [
            Shortcut(keys: ["⌘]", "⌘["], action: "Next or previous file"),
            Shortcut(keys: ["⌥⌘]", "⌥⌘["], action: "Next or previous thread"),
            Shortcut(keys: ["⇧⌘A"], action: "Next thread that needs you"),
            Shortcut(keys: ["⇧⌘]", "⇧⌘["], action: "Layer above or below"),
            Shortcut(keys: ["⌘1", "⌘9"], action: "Go to layer 1 to 9", joiner: "to"),
            Shortcut(keys: ["⇧⌘↩"], action: "Finish review"),
            Shortcut(keys: ["⌘C"], action: "Copy the selected code"),
        ]),
        Group(title: "In a comment box", note: nil, shortcuts: [
            Shortcut(keys: ["⌘↩"], action: "Add to review"),
            Shortcut(keys: ["⌥⌘↩"], action: "Send now"),
            Shortcut(keys: ["⇧⌘P"], action: "Preview the Markdown, or go back to writing"),
            Shortcut(keys: ["Esc"], action: "Close and keep the draft"),
        ]),
        Group(title: "In Finish review", note: nil, shortcuts: [
            Shortcut(keys: ["⌘↩"], action: "Submit review"),
            Shortcut(keys: ["Esc"], action: "Close and keep the summary"),
        ]),
    ]

    var body: some View {
        ScrollView {
            KeyboardShortcutsTable()
        }
        .frame(width: 460, height: 620)
        .navigationTitle(Self.title)
    }
}

/// The groups of shortcuts, laid out as a table, without the window's scroll view.
struct KeyboardShortcutsTable: View {
    /// Every row's keys sit in a column of this width, so the actions line up.
    static let keysColumnWidth: CGFloat = 136

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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.shortcuts) { shortcut in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                ShortcutKeys(shortcut: shortcut)
                                    .frame(width: Self.keysColumnWidth, alignment: .leading)
                                Text(shortcut.action)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A shortcut's keys as keycaps, with "or" or "to" between them.
private struct ShortcutKeys: View {
    let shortcut: KeyboardShortcutsView.Shortcut

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Text(shortcut.joiner)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Keycap(key: key)
            }
        }
    }
}

/// One key or chord, such as ⇧⌘A, drawn as a key on a keyboard.
private struct Keycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
    }
}
