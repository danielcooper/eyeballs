import AppKit
import SwiftUI

/// What the layer overview can ask the pane to do.
struct OverviewActions {
    var commentOnLayer: @MainActor () -> Void = {}
    /// Goes to the layer at a position in the stack.
    var showLayer: @MainActor (Int) -> Void = { _ in }
}

/// The top of the pane: which layer this is, what it builds on, its commits, and
/// "Comment on layer".
struct LayerOverviewCard: View {
    let content: OverviewContent
    let actions: OverviewActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(positionText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(content.layer?.branch ?? "Layer")
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let number = content.layer?.prNumber {
                            Text("#\(number)")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        if let status = content.layer?.status {
                            LayerStatusChip(status: status)
                        }
                    }
                    buildsOn
                }
                Spacer(minLength: 12)
                Button(action: actions.commentOnLayer) {
                    Label("Comment on layer", systemImage: "text.bubble")
                }
                .help("Start a thread about this whole layer")
            }

            HStack(spacing: 16) {
                stat(symbol: "point.3.connected.trianglepath.dotted", text: count(content.commits.count, "commit"))
                stat(symbol: "doc.on.doc", text: count(content.fileCount, "file"))
                HStack(spacing: 4) {
                    Text("+\(content.additions)").foregroundStyle(Color.diffAddedText)
                    Text("−\(content.deletions)").foregroundStyle(Color.diffDeletedText)
                }
                .font(.callout.weight(.semibold).monospaced())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(content.additions) lines added, \(content.deletions) lines deleted")
                stat(symbol: "bubble.left", text: content.threadCount == 0 ? "No open threads" : count(content.threadCount, "open thread"))
            }

            if !content.commits.isEmpty {
                CommitTimeline(commits: content.commits)
            }
        }
        .frame(maxWidth: ThreadLayout.maxCardWidth, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.paneBackground)
    }

    /// "Builds on models", with the layer's name as a link to it. The trunk is plain text.
    @ViewBuilder
    private var buildsOn: some View {
        if let parent = content.parentLayer {
            HStack(spacing: 4) {
                Text("Builds on")
                    .foregroundStyle(.secondary)
                Button(parent.branch) { actions.showLayer(parent.position) }
                    .buttonStyle(.link)
                    .help("Go to layer \(parent.position), \(parent.branch)")
            }
            .font(.callout)
        } else if let trunk = content.parentBranch {
            Text("Builds on \(trunk)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var positionText: String {
        guard let layer = content.layer, content.layerCount > 0 else { return "LAYER OVERVIEW" }
        return "LAYER \(layer.position) OF \(content.layerCount)"
    }

    private func stat(symbol: String, text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    private func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }
}

/// The layer's commits, newest first, on a line like `git log --graph`.
private struct CommitTimeline: View {
    let commits: [CommitItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                CommitRow(commit: commit, isNewest: index == 0, isOldest: index == commits.count - 1)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.diffBorder))
    }
}

/// One commit: its node on the line, subject, author and age, and its SHA as a copy button.
private struct CommitRow: View {
    static let height: CGFloat = 32

    let commit: CommitItem
    let isNewest: Bool
    let isOldest: Bool
    @State private var isHovered = false
    @State private var copied = false

    private var shortSHA: String { String(commit.sha.prefix(7)) }

    var body: some View {
        HStack(spacing: 12) {
            TimelineNode(continuesUp: !isNewest, continuesDown: !isOldest)
            Text(commit.subject)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text("\(commit.author) · \(RelativeTime.text(for: commit.date))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Button(action: copySHA) {
                Label(copied ? "Copied" : shortSHA, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.monospaced())
                    .frame(minWidth: 88, alignment: .trailing)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isHovered || copied ? Color.accentColor : Color.secondary)
            .help("Copy the full SHA")
            .accessibilityLabel(copied ? "Copied" : "Copy SHA \(shortSHA)")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy SHA") { copy(commit.sha) }
            Button("Copy Subject") { copy(commit.subject) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Commit \(shortSHA): \(commit.subject), by \(commit.author)")
    }

    private func copySHA() {
        copy(commit.sha)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A commit's dot, with the line running through it to the commits above and below.
private struct TimelineNode: View {
    let continuesUp: Bool
    let continuesDown: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle().fill(continuesUp ? Color.secondary.opacity(0.45) : Color.clear)
                Rectangle().fill(continuesDown ? Color.secondary.opacity(0.45) : Color.clear)
            }
            .frame(width: 2)
            Circle()
                .fill(Color.cardBackground)
                .overlay(Circle().strokeBorder(Color.secondary, lineWidth: 2))
                .frame(width: 10, height: 10)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}
