import SwiftUI

/// What a thread card can ask the pane to do.
struct ThreadCardActions {
    var focus: @MainActor () -> Void = {}
    var reply: @MainActor () -> Void = {}
    var setResolved: @MainActor (Bool) -> Void = { _ in }
    var toggleExpanded: @MainActor () -> Void = {}
    var edit: @MainActor (Int) -> Void = { _ in }
    var delete: @MainActor (Int) -> Void = { _ in }
    var deleteThread: @MainActor () -> Void = {}
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
                    Divider().overlay(Color.diffBorder.opacity(0.6)).padding(.leading, 48)
                }
                CommentView(comment: comment, isFirst: index == 0, thread: thread, actions: actions)
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
        .simultaneousGesture(TapGesture().onEnded { actions.focus() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread t\(thread.id), \(thread.state.label), \(content.anchorText)")
    }

    /// The thread's one state chip, plus "Outdated" when its lines are gone.
    private var header: some View {
        HStack(spacing: 8) {
            ThreadStateChip(state: thread.state)
            if thread.isOutdated {
                Chip(text: "Outdated", symbol: "clock.arrow.circlepath", tint: .gray)
                    .help("The lines this thread was on are gone. It shows the code it was written on.")
            }
            Text(content.anchorText)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("t\(thread.id)")
                .font(.subheadline.monospaced())
                .foregroundStyle(.tertiary)
            if thread.isResolved {
                Button(action: actions.toggleExpanded) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Collapse this resolved thread")
                .accessibilityLabel("Collapse thread")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.cardHeader)
    }

    /// Reply, and Resolve once the agent has seen the thread. A draft has nothing to resolve.
    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: actions.reply) {
                HStack {
                    Text("Reply…").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.body)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.diffBorder))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reply in this thread (r)")
            .accessibilityLabel("Reply to thread t\(thread.id)")

            if thread.state != .draft {
                Button(thread.isResolved ? "Reopen" : "Resolve") {
                    actions.setResolved(!thread.isResolved)
                }
                .help(thread.isResolved ? "Open this thread again (e)" : "Mark this thread resolved (e)")
                .accessibilityLabel(thread.isResolved ? "Reopen thread t\(thread.id)" : "Resolve thread t\(thread.id)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.cardHeader)
    }
}

/// One comment. The thread's chip carries its state, so a reply's status is quiet text here,
/// and "Pending" shows only beside your unsent replies in a thread the agent has seen.
struct CommentView: View {
    let comment: CommentItem
    let isFirst: Bool
    let thread: ThreadItem
    let actions: ThreadCardActions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(author: comment.author)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(comment.author.name)
                        .font(.body.weight(.semibold))
                        .padding(.trailing, 2)
                    Text(RelativeTime.text(for: comment.date))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help(comment.date.formatted(date: .abbreviated, time: .shortened))
                    if let status = comment.replyStatus {
                        Text("· \(status.label.lowercased())")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if comment.isEdited {
                        Text("· edited")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    if comment.isPending, thread.hasSentComments {
                        Chip(text: "Pending", symbol: nil, tint: .yellow, isSmall: true)
                            .padding(.leading, 4)
                            .help("In your review. The agent sees it when you submit.")
                    }
                    Spacer(minLength: 0)
                    if !comment.author.isAgent {
                        Menu {
                            Button("Edit") { actions.edit(comment.id) }
                            Divider()
                            if deletesThread {
                                Button(deleteTitle, role: .destructive, action: actions.deleteThread)
                            } else {
                                Button(deleteTitle, role: .destructive) { actions.delete(comment.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 16)
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
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    /// The first comment opens the thread, so deleting it deletes the thread.
    private var deletesThread: Bool { isFirst }

    private var deleteTitle: String {
        if isFirst { return thread.comments.count == 1 && comment.isPending ? "Delete" : "Delete Thread…" }
        return comment.isPending ? "Delete" : "Delete…"
    }
}

struct NoteLine: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(lines.joined(separator: "\n"))
                .font(.callout.monospaced())
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(MarkdownText.attributed(firstWords))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardHeader))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isFocused ? Color.accentColor : Color.diffBorder, lineWidth: isFocused ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this resolved thread")
        .accessibilityLabel("Resolved thread t\(content.thread.id): \(String(MarkdownText.attributed(firstWords).characters)). Show it.")
    }
}
