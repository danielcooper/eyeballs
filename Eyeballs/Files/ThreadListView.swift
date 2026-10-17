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
                    Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .imageScale(.large)
                        .foregroundStyle(isFiltered ? Color.accentColor : Color.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show only some threads: \(windowState.threadFilter.label)")
                .accessibilityLabel("Filter threads, showing \(windowState.threadFilter.label)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if isFiltered {
                filterLine
            }
            content
        }
    }

    private var isFiltered: Bool { windowState.threadFilter != .all }

    /// "Showing outdated threads · 1 of 7", so a filtered list never passes for the whole list.
    private var filterLine: some View {
        let scoped = threadsInScope
        let shown = scoped.filter(windowState.threadFilter.includes).count
        return HStack(spacing: 8) {
            // No-break spaces keep "· 1 of 10" together when the line wraps.
            Text("\(windowState.threadFilter.showingText)\u{00A0}·\u{00A0}\(shown)\u{00A0}of\u{00A0}\(scoped.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1...2)
            Spacer(minLength: 4)
            Button("Show All") { windowState.threadFilter = .all }
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    /// Every thread the scope covers, before the filter.
    private var threadsInScope: [ThreadItem] {
        switch windowState.threadScope {
        case .thisLayer: model.layer?.threads ?? []
        case .wholeStack: (model.selectedStack?.layers ?? []).flatMap { threads(onLayer: $0.id) }
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
                            ThreadListRow(thread: thread, showsState: group.showsState)
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
                return threads.isEmpty ? nil : Group(title: "Layer \(layer.position) · \(layer.branch)", threads: threads, showsState: true)
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
        /// False when the heading already names every thread's state, as "Drafts" does.
        var showsState: Bool
    }

    static func groups(_ threads: [ThreadItem]) -> [Group] {
        let sorted = threads.sorted { ($0.state.listOrder, $0.id) < ($1.state.listOrder, $1.id) }
        let candidates = [
            Group(title: "Needs you", threads: sorted.filter { $0.state.needsYou }, showsState: true),
            Group(title: "Drafts", threads: sorted.filter { $0.state == .draft }, showsState: false),
            Group(title: "Waiting on agent", threads: sorted.filter { $0.state == .waitingOnAgent }, showsState: false),
            Group(title: "Resolved", threads: sorted.filter { $0.state == .resolved }, showsState: false),
        ]
        return candidates.filter { !$0.threads.isEmpty }
    }
}

private struct ThreadListRow: View {
    let thread: ThreadItem
    let showsState: Bool

    private var lastComment: CommentItem? { thread.comments.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsState || thread.isOutdated {
                HStack(spacing: 4) {
                    if showsState {
                        ThreadStateChip(state: thread.state)
                    }
                    if thread.isOutdated {
                        Chip(text: "Outdated", symbol: "clock.arrow.circlepath", tint: .gray, isSmall: true)
                    }
                }
            }
            ThreadLocationText(anchor: thread.anchor)
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

/// Where a thread sits, such as "Sources/API/Client.swift:41–47". When space runs short the
/// folder shortens from its start; the file name and the lines always show in full.
struct ThreadLocationText: View {
    let anchor: ThreadAnchor

    private var folder: String? {
        let path: String? = switch anchor {
        case .lines(let range): range.path
        case .file(let path): path
        case .layer: nil
        }
        guard let folder = path.map({ ($0 as NSString).deletingLastPathComponent }), !folder.isEmpty else { return nil }
        return folder + "/"
    }

    var body: some View {
        HStack(spacing: 0) {
            if let folder {
                Text(folder)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(DiffRowBuilder.anchorText(for: anchor))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .font(.subheadline.monospaced())
        .accessibilityElement(children: .combine)
    }
}
