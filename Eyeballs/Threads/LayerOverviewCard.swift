import SwiftUI

/// The top of the pane: which layer this is, its commits, and "Comment on layer".
struct LayerOverviewCard: View {
    let content: OverviewContent
    var onCommentOnLayer: @MainActor () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(positionText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(content.layer?.branch ?? "Layer")
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let number = content.layer?.prNumber {
                            Text("#\(number)")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        }
                        if let status = content.layer?.status {
                            LayerStatusChip(status: status)
                        }
                    }
                    if let parent = content.parentBranch {
                        Text("Builds on \(parent)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Button(action: onCommentOnLayer) {
                    Label("Comment on layer", systemImage: "text.bubble")
                }
                .controlSize(.regular)
                .help("Start a thread about this whole layer")
            }

            HStack(spacing: 16) {
                stat(symbol: "point.3.connected.trianglepath.dotted", text: count(content.commits.count, "commit"))
                stat(symbol: "doc.on.doc", text: count(content.fileCount, "file"))
                HStack(spacing: 4) {
                    Text("+\(content.additions)").foregroundStyle(Color.diffAddedText)
                    Text("−\(content.deletions)").foregroundStyle(Color.diffDeletedText)
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(content.additions) lines added, \(content.deletions) lines deleted")
                stat(symbol: "bubble.left", text: content.threadCount == 0 ? "No open threads" : count(content.threadCount, "open thread"))
            }

            if !content.commits.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(content.commits.enumerated()), id: \.element.id) { index, commit in
                        if index > 0 { Divider().overlay(Color.diffBorder.opacity(0.7)) }
                        CommitLine(commit: commit)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.diffBorder))
            }
        }
        .frame(maxWidth: ThreadLayout.maxCardWidth, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.paneBackground)
    }

    private var positionText: String {
        guard let layer = content.layer, content.layerCount > 0 else { return "LAYER OVERVIEW" }
        return "LAYER \(layer.position) OF \(content.layerCount)"
    }

    private func stat(symbol: String, text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    private func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }
}

private struct CommitLine: View {
    let commit: CommitItem

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 1.5)
                .frame(width: 9, height: 9)
            Text(String(commit.sha.prefix(7)))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(commit.subject)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text("\(commit.author) · \(RelativeTime.text(for: commit.date))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Commit \(commit.sha.prefix(7)): \(commit.subject), by \(commit.author)")
    }
}
