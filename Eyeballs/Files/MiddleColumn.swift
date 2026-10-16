import SwiftUI

/// The middle column: the layer's files, or every thread on it.
struct MiddleColumn: View {
    let model: ReviewWindowModel
    @Bindable var windowState: ReviewWindowState

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $windowState.middleTab) {
                Text("Files").tag(ReviewWindowState.MiddleTab.files)
                Text("Threads").tag(ReviewWindowState.MiddleTab.threads)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            Group {
                if model.layer == nil, model.isLoadingLayer {
                    ProgressView("Loading layer…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch windowState.middleTab {
                    case .files: FileListView(model: model, windowState: windowState)
                    case .threads: ThreadListView(model: model, windowState: windowState)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
    }
}

struct FileListView: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState

    private enum Item: Hashable {
        case overview
        case file(String)
    }

    var body: some View {
        if let layer = model.layer {
            List(selection: selection) {
                OverviewRow(commitCount: layer.commits.count, layerThreads: layer.threads.filter { $0.anchor == .layer && !$0.isResolved }.count)
                    .tag(Item.overview)
                Section(Self.fileCountTitle(layer.files.count)) {
                    ForEach(layer.files) { file in
                        FileRow(file: file, threadCount: openThreads(in: file.path, of: layer))
                            .tag(Item.file(file.path))
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView("No layer", systemImage: "doc.on.doc", description: Text("Pick a layer to see its files."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func fileCountTitle(_ count: Int) -> String {
        switch count {
        case 0: "No files changed"
        case 1: "1 file"
        default: "\(count) files"
        }
    }

    private var selection: Binding<Item?> {
        Binding {
            windowState.currentFilePath.map(Item.file) ?? .overview
        } set: { item in
            switch item {
            case .overview: windowState.revealOverview()
            case .file(let path): windowState.revealFile(path)
            case nil: break
            }
        }
    }

    private func openThreads(in path: String, of layer: LayerContent) -> Int {
        layer.threads.filter { thread in
            guard !thread.isResolved else { return false }
            switch thread.anchor {
            case .file(let filePath): return filePath == path
            case .lines(let range): return range.path == path
            case .layer: return false
            }
        }.count
    }
}

private struct OverviewRow: View {
    let commitCount: Int
    let layerThreads: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.text.square")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Layer overview")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(commitCount == 1 ? "1 commit" : "\(commitCount) commits")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ThreadCountBadge(count: layerThreads)
        }
        .padding(.vertical, 3)
    }
}

struct FileRow: View {
    let file: FileItem
    let threadCount: Int

    @MainActor private var style: FileChangeStyle { FileChangeStyle(file.change) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: style.symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: style.color))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text((file.path as NSString).lastPathComponent)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let words = style.wordsShownInHeader {
                        Text(words)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(folderLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(file.oldPath == nil ? .head : .middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if file.isBinary {
                    Text("Binary")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 3) {
                        Text("+\(file.additions)").foregroundStyle(Color.diffAddedText)
                        Text("−\(file.deletions)").foregroundStyle(Color.diffDeletedText)
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                ThreadCountBadge(count: threadCount)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var folderLine: String {
        let folder = (file.path as NSString).deletingLastPathComponent
        if let oldPath = file.oldPath {
            let sameFolder = (oldPath as NSString).deletingLastPathComponent == folder
            return "from \(sameFolder ? (oldPath as NSString).lastPathComponent : oldPath)"
        }
        return folder.isEmpty ? "/" : folder
    }

    private var accessibilityText: String {
        var parts = [file.path, style.words]
        if let oldPath = file.oldPath { parts.append("from \(oldPath)") }
        parts.append(file.isBinary ? "binary" : "\(file.additions) added, \(file.deletions) deleted")
        if threadCount > 0 { parts.append(threadCount == 1 ? "1 open thread" : "\(threadCount) open threads") }
        return parts.joined(separator: ", ")
    }
}

struct ThreadCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: "bubble.left.fill")
                Text("\(count)")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel(count == 1 ? "1 open thread" : "\(count) open threads")
        }
    }
}
