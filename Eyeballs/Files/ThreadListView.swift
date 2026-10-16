import SwiftUI

/// The layer's threads grouped so that what needs you comes first, or the whole stack's
/// threads grouped by layer. A filter narrows either to one kind of thread.
struct ThreadListView: View {
    let model: ReviewWindowModel
    @Bindable var windowState: ReviewWindowState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Scope", selection: $windowState.threadScope) {
                    ForEach(ThreadScope.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Menu {
                    Picker("Show", selection: $windowState.threadFilter) {
                        ForEach(ThreadFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: windowState.threadFilter == .all
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show only some threads: \(windowState.threadFilter.label)")
                .accessibilityLabel("Filter threads, showing \(windowState.threadFilter.label)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let shown = groups
        if shown.isEmpty {
            emptyState
        } else {
            List(selection: selection) {
                ForEach(shown, id: \.title) { group in
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

    @ViewBuilder
    private var emptyState: some View {
        if windowState.threadFilter != .all {
            ContentUnavailableView {
                Label("No threads to show", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing here is \(windowState.threadFilter.label.lowercased()).")
            } actions: {
                Button("Show All Threads") { windowState.threadFilter = .all }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No threads yet",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Click a line number, or the blue + beside a line, to start one."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var groups: [Group] {
        switch windowState.threadScope {
        case .thisLayer:
            return Self.groups((model.layer?.threads ?? []).filter(windowState.threadFilter.includes))
        case .wholeStack:
            guard let stack = model.selectedStack else { return [] }
            return stack.layers.sorted { $0.position > $1.position }.compactMap { layer in
                let threads = threads(onLayer: layer.id).filter(windowState.threadFilter.includes)
                    .sorted { ($0.state.listOrder, $0.id) < ($1.state.listOrder, $1.id) }
                return threads.isEmpty ? nil : Group(title: "\(layer.position) \(layer.branch)", threads: threads)
            }
        }
    }

    /// The shown layer's threads come from the layer itself, which is always the freshest.
    private func threads(onLayer id: Int) -> [ThreadItem] {
        if let layer = model.layer, layer.layerID == id { return layer.threads }
        return model.threadsByLayer[id] ?? []
    }

    private var selection: Binding<Int?> {
        Binding {
            windowState.focusedThreadID
        } set: { id in
            if let id { windowState.showThread(id, in: model) }
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
            HStack(spacing: 4) {
                ThreadStateChip(state: thread.state)
                if thread.isOutdated {
                    Chip(text: "Outdated", symbol: "clock.arrow.circlepath", tint: .gray, isSmall: true)
                }
                Spacer(minLength: 4)
                Text("t\(thread.id)")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Text(DiffRowBuilder.anchorText(for: thread.anchor))
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let lastComment {
                (Text(lastComment.author.name + ": ").fontWeight(.semibold) + Text(MarkdownText.attributed(firstLine(of: lastComment.body))))
                    .font(.callout)
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
