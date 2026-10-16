import SwiftUI

/// Every thread on the layer, grouped so that what needs you comes first.
struct ThreadListView: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState

    var body: some View {
        let groups = Self.groups(model.layer?.threads ?? [])
        if groups.isEmpty {
            ContentUnavailableView(
                "No threads yet",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Click a line number, or the blue + beside a line, to start one."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: selection) {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.threads) { thread in
                            ThreadListRow(thread: thread)
                                .tag(thread.id)
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var selection: Binding<Int?> {
        Binding {
            windowState.focusedThreadID
        } set: { id in
            if let id { windowState.revealThread(id) }
        }
    }

    struct Group {
        var title: String
        var threads: [ThreadItem]
    }

    static func groups(_ threads: [ThreadItem]) -> [Group] {
        let sorted = threads.sorted { ($0.state.listOrder, $0.id) < ($1.state.listOrder, $1.id) }
        let candidates = [
            Group(title: "Needs you", threads: sorted.filter { $0.state.needsYou }),
            Group(title: "Drafts", threads: sorted.filter { $0.state == .draft }),
            Group(title: "Waiting on agent", threads: sorted.filter { $0.state == .waitingOnAgent }),
            Group(title: "Resolved", threads: sorted.filter { $0.state == .resolved }),
        ]
        return candidates.filter { !$0.threads.isEmpty }
    }
}

private struct ThreadListRow: View {
    let thread: ThreadItem

    private var lastComment: CommentItem? { thread.comments.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ThreadStateChip(state: thread.state)
                Spacer(minLength: 4)
                Text("t\(thread.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(DiffRowBuilder.anchorText(for: thread.anchor))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let lastComment {
                (Text(lastComment.author.name + ": ").fontWeight(.semibold) + Text(MarkdownText.attributed(firstLine(of: lastComment.body))))
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundStyle(thread.isResolved ? .secondary : .primary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func firstLine(of body: String) -> String {
        body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
