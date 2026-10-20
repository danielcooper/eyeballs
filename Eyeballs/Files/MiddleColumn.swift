import SwiftUI

struct MiddleColumn: View {
    let model: ReviewWindowModel
    @Bindable var windowState: ReviewWindowState

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $windowState.middleTab) {
                Text("Files").tag(ReviewWindowState.MiddleTab.files)
                Text("Commits").tag(ReviewWindowState.MiddleTab.commits)
                Text("Threads").tag(ReviewWindowState.MiddleTab.threads)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            Group {
                if model.layer == nil, model.isLoadingLayer {
                    LoadingFileList()
                } else if model.layer == nil {
                    // The diff column says why there is nothing here, so this one stays blank.
                    Color.clear
                } else {
                    switch windowState.middleTab {
                    case .files: FileListView(model: model, windowState: windowState)
                    case .commits: CommitListView(model: model)
                    case .threads: ThreadListView(model: model, windowState: windowState)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
    }
}

/// The layer's commits, newest first, under an "All changes" row. Picking one shows just that
/// commit's diff.
struct CommitListView: View {
    let model: ReviewWindowModel

    var body: some View {
        if let layer = model.layer {
            List(selection: selection) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All changes").font(.body.weight(.semibold))
                        Text(layer.commits.count == 1 ? "1 commit" : "\(layer.commits.count) commits")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .tag("")
                Section("Commits") {
                    ForEach(layer.commits) { commit in
                        CommitRow(commit: commit).tag(commit.sha)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var selection: Binding<String?> {
        Binding {
            model.commitFocus?.sha ?? ""
        } set: { sha in
            let focus = sha.flatMap { $0.isEmpty ? nil : $0 }
            if focus != model.commitFocus?.sha { model.focusCommit(focus) }
        }
    }
}

private struct CommitRow: View {
    let commit: CommitItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "smallcircle.filled.circle")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(String(commit.sha.prefix(7))).font(.subheadline.monospaced())
                    Text("·")
                    Text(commit.author)
                    Text("·")
                    Text(commit.date, style: .relative)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
                Section {
                    ForEach(layer.files) { file in
                        FileRow(file: file, threadCount: openThreads(in: file.path, of: layer), isViewed: Binding {
                            windowState.isViewed(file, layerID: layer.layerID)
                        } set: { viewed in
                            windowState.pane?.setViewed(viewed, path: file.path)
                        })
                        .tag(Item.file(file.path))
                    }
                } header: {
                    ViewedProgress(fileCount: layer.files.count, viewedCount: windowState.viewedCount(in: layer))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
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

/// "5 files · 2 viewed", with a bar that fills as you tick files off.
private struct ViewedProgress: View {
    let fileCount: Int
    let viewedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(fileCount == 1 ? "1 file" : "\(fileCount) files")
                Spacer()
                if fileCount > 0 {
                    Text("\(viewedCount) of \(fileCount) viewed")
                        .monospacedDigit()
                }
            }
            if fileCount > 0 {
                ProgressView(value: Double(viewedCount), total: Double(fileCount))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(viewedCount == fileCount ? .green : .accentColor)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewRow: View {
    let commitCount: Int
    let layerThreads: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.text.square")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Layer overview")
                    .font(.body.weight(.semibold))
                Text(commitCount == 1 ? "1 commit" : "\(commitCount) commits")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ThreadCountBadge(count: layerThreads)
        }
        .padding(.vertical, 4)
    }
}

struct FileRow: View {
    let file: FileItem
    let threadCount: Int
    var isViewed: Binding<Bool> = .constant(false)

    @MainActor private var style: FileChangeStyle { FileChangeStyle(file.change) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.symbol)
                .font(.body)
                .foregroundStyle(Color(nsColor: style.color))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isViewed.wrappedValue ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if let words = style.wordsShownInHeader {
                        Text("\(words) ·")
                            .fontWeight(.medium)
                            .fixedSize()
                    }
                    Text(folderLine)
                        .lineLimit(1)
                        .truncationMode(file.oldPath == nil ? .head : .middle)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if file.isBinary {
                    Text("Binary")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    LineCountsText(additions: file.additions, deletions: file.deletions)
                }
                ThreadCountBadge(count: threadCount)
            }
            Toggle("Viewed", isOn: isViewed)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .help(isViewed.wrappedValue ? "Viewed. Untick to show this file again." : "Mark this file viewed and fold it away")
                .accessibilityLabel("Viewed \((file.path as NSString).lastPathComponent)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
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
        if isViewed.wrappedValue { parts.append("viewed") }
        return parts.joined(separator: ", ")
    }
}

/// Grey stand-ins for the file list while a layer loads. The one spinner is in the diff pane.
private struct LoadingFileList: View {
    private static let samples: [FileItem] = [
        ("Sources/Feature/Placeholder.swift", 24, 6), ("Sources/Feature/Shorter.swift", 8, 2),
        ("Tests/FeatureTests/PlaceholderTests.swift", 40, 0), ("Resources/placeholder.json", 3, 3),
    ].map { path, added, deleted in
        FileItem(path: path, oldPath: nil, change: .modified, additions: added, deletions: deleted, isBinary: false,
                 hunks: [], newLines: [], oldLines: [])
    }

    var body: some View {
        List {
            OverviewRow(commitCount: 3, layerThreads: 0)
            Section("Files") {
                ForEach(Self.samples) { file in
                    FileRow(file: file, threadCount: 0)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .redacted(reason: .placeholder)
        .disabled(true)
        .accessibilityLabel("Loading the layer's files")
    }
}

struct ThreadCountBadge: View {
    let count: Int
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: "bubble.left.fill")
                Text("\(count)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(Color.selectedText) : AnyShapeStyle(.secondary))
            .accessibilityLabel(count == 1 ? "1 open thread" : "\(count) open threads")
        }
    }
}
