import SwiftUI

/// What a thread card can ask the pane to do.
struct ThreadCardActions {
    var focus: @MainActor () -> Void = {}
    var reply: @MainActor () -> Void = {}
    var setResolved: @MainActor (Bool) -> Void = { _ in }
    var toggleExpanded: @MainActor () -> Void = {}
    var edit: @MainActor (Int) -> Void = { _ in }
    var delete: @MainActor (Int) -> Void = { _ in }
}

/// One thread row in the pane: a full card, or one slim line for a resolved thread.
///
/// The row is measured with `sizeThatFits` at the table's real width, so everything here must
/// size itself from the width it is offered.
struct ThreadRowRoot: View {
    let content: ThreadRowContent
    let isFocused: Bool
    let actions: ThreadCardActions

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: content.leadingInset, height: 1)
            Group {
                if content.isCollapsed {
                    ResolvedThreadBar(content: content, isFocused: isFocused, actions: actions)
                } else {
                    ThreadCard(content: content, isFocused: isFocused, actions: actions)
                }
            }
            .frame(maxWidth: ThreadLayout.maxCardWidth, alignment: .leading)
            Spacer(minLength: ThreadLayout.trailingMargin)
        }
        .padding(.top, ThreadLayout.rowMargin)
        .padding(.bottom, content.hasComposerBelow ? 0 : ThreadLayout.rowMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.paneBackground)
    }
}

struct ThreadCard: View {
    let content: ThreadRowContent
    let isFocused: Bool
    let actions: ThreadCardActions

    private var thread: ThreadItem { content.thread }

    private var shape: UnevenRoundedRectangle {
        let bottom: CGFloat = content.hasComposerBelow ? 0 : 8
        return UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.diffBorder)
            if let note = content.placementNote {
                NoteLine(text: note, symbol: "info.circle", tint: .secondary)
            }
            if let note = thread.anchorNote {
                NoteLine(text: note, symbol: thread.originalLines.isEmpty ? "arrow.turn.down.right" : "exclamationmark.triangle.fill", tint: .orange)
            }
            if !thread.originalLines.isEmpty {
                OriginalLines(lines: thread.originalLines)
            }
            ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                if index > 0 {
                    Divider().overlay(Color.diffBorder.opacity(0.6)).padding(.leading, 46)
                }
                CommentView(comment: comment, actions: actions)
            }
            if !content.hasComposerBelow {
                Divider().overlay(Color.diffBorder)
                footer
            }
        }
        .background(Color.cardBackground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(isFocused ? Color.accentColor : Color.diffBorder, lineWidth: isFocused ? 2 : 1))
        .contentShape(shape)
        .onTapGesture { actions.focus() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread t\(thread.id), \(thread.state.label), \(content.anchorText)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            ThreadStateChip(state: thread.state)
            Text(content.anchorText)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("t\(thread.id)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            if thread.isResolved {
                Button(action: actions.toggleExpanded) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Collapse this resolved thread")
                .accessibilityLabel("Collapse thread")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.cardHeader)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: actions.reply) {
                HStack {
                    Text("Reply…").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.diffBorder))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reply in this thread (r)")
            .accessibilityLabel("Reply to thread t\(thread.id)")

            Button(thread.isResolved ? "Reopen" : "Resolve") {
                actions.setResolved(!thread.isResolved)
            }
            .controlSize(.regular)
            .help(thread.isResolved ? "Open this thread again (e)" : "Mark this thread resolved (e)")
            .accessibilityLabel(thread.isResolved ? "Reopen thread t\(thread.id)" : "Resolve thread t\(thread.id)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.cardHeader)
    }
}

struct CommentView: View {
    let comment: CommentItem
    let actions: ThreadCardActions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(author: comment.author)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.author.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(RelativeTime.text(for: comment.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .help(comment.date.formatted(date: .abbreviated, time: .shortened))
                    if comment.isPending {
                        Chip(text: "Pending", symbol: nil, tint: .yellow, isSmall: true)
                            .help("In your review. The agent sees it when you submit.")
                    }
                    if let status = comment.replyStatus {
                        ReplyStatusChip(status: status)
                    }
                    if comment.isEdited {
                        Text("edited")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if !comment.author.isAgent {
                        Menu {
                            Button("Edit") { actions.edit(comment.id) }
                            Button("Delete", role: .destructive) { actions.delete(comment.id) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 18)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More actions for this comment")
                    }
                }
                MarkdownText(comment.body)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

struct NoteLine: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The code an outdated thread was written on.
struct OriginalLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Originally:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.codeBlock))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.diffBorder))
                .accessibilityLabel("Original code: \(lines.joined(separator: ", "))")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// A resolved thread folded to one line. A click opens the full card.
struct ResolvedThreadBar: View {
    let content: ThreadRowContent
    let isFocused: Bool
    let actions: ThreadCardActions

    private var firstWords: String {
        let body = content.thread.comments.first?.body ?? ""
        return body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    var body: some View {
        Button(action: actions.toggleExpanded) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Resolved")
                    .fontWeight(.semibold)
                Text("·").foregroundStyle(.tertiary)
                Text("t\(content.thread.id)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(MarkdownText.attributed(firstWords))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardHeader))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isFocused ? Color.accentColor : Color.diffBorder, lineWidth: isFocused ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this resolved thread")
        .accessibilityLabel("Resolved thread t\(content.thread.id): \(String(MarkdownText.attributed(firstWords).characters)). Show it.")
    }
}
