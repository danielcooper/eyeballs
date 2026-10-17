import SwiftUI

/// The bar under the diff: what is pending, what was delivered, and the Finish review button.
///
/// It keeps one height whatever it shows, so the diff above it never moves.
struct ReviewBar: View {
    static let height: CGFloat = 52

    let model: ReviewWindowModel
    @Bindable var windowState: ReviewWindowState

    var body: some View {
        HStack(spacing: 12) {
            ReviewStatus(review: model.review, agentName: model.agent.agentName)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !model.agent.isListening {
                Button("Copy prompt") { model.copyAgentPrompt() }
                    .fixedSize()
                    .help("No agent is listening. Copy a prompt that tells one to read this review.")
            }
            finishButton
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var pendingCount: Int { model.review.pendingCommentCount }

    private var finishButton: some View {
        Button {
            windowState.finishReview(model)
        } label: {
            HStack(spacing: 8) {
                Text("Finish review")
                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.28)))
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(model.selectedStack == nil)
        .help("Add a summary, pick a verdict and send your review (⇧⌘↩)")
        .accessibilityLabel(pendingCount == 0 ? "Finish review" : "Finish review, \(Self.pendingText(pendingCount))")
        .popover(isPresented: $windowState.isFinishingReview, arrowEdge: .top) {
            FinishReviewPopover(model: model, windowState: windowState)
        }
    }

    static func pendingText(_ count: Int) -> String {
        switch count {
        case 0: "No pending comments"
        case 1: "1 pending comment"
        default: "\(count) pending comments"
        }
    }

    static func deliveryText(_ review: SubmittedReview, agentName: String?) -> String {
        let agent = agentName ?? "the agent"
        guard let delivered = review.deliveredAt else { return "Review \(review.number) sent · waiting for \(agent)" }
        return "Review \(review.number) delivered to \(agent) at \(delivered.formatted(date: .omitted, time: .shortened))"
    }
}

/// The pending count, and under it how the last review got on.
private struct ReviewStatus: View {
    let review: PendingReview
    let agentName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: review.pendingCommentCount > 0 ? "bubble.left.fill" : "bubble.left")
                    .foregroundStyle(review.pendingCommentCount > 0 ? Color.yellow : Color.secondary)
                Text(ReviewBar.pendingText(review.pendingCommentCount))
                    .font(.body.weight(.semibold))
            }
            if let submitted = review.lastSubmitted {
                HStack(spacing: 4) {
                    Image(systemName: submitted.deliveredAt == nil ? "paperplane" : "checkmark.circle.fill")
                        .foregroundStyle(submitted.deliveredAt == nil ? Color.secondary : Color.green)
                    Text(ReviewBar.deliveryText(submitted, agentName: agentName))
                        .truncationMode(.tail)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// GitHub's "Finish your review": a summary, a verdict and a Submit button, run by ⌘↩.
///
/// Return always adds a line to the summary. Only the Submit button, or ⌘↩, sends anything.
struct FinishReviewPopover: View {
    let model: ReviewWindowModel
    @Bindable var windowState: ReviewWindowState
    @FocusState private var summaryIsFocused: Bool

    private var agent: String { model.agent.agentName ?? "the agent" }
    private var agentStartingASentence: String { agent.prefix(1).uppercased() + agent.dropFirst() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish your review")
                    .font(.headline)
                Text(ReviewBar.pendingText(model.review.pendingCommentCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            SummaryEditor(text: $windowState.summaryText, placeholder: "Leave a summary for \(agent) (optional). Markdown works.")
                .focused($summaryIsFocused)
                .frame(height: 112)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Verdict.allCases, id: \.self) { verdict in
                    VerdictOption(
                        verdict: verdict, description: description(of: verdict),
                        isSelected: windowState.verdict == verdict) { windowState.verdict = verdict }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Text(model.agent.isListening ? "\(agentStartingASentence) gets it at once." : "No agent is listening yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel") { windowState.isFinishingReview = false }
                    .keyboardShortcut(.cancelAction)
                Button("Submit review") { windowState.submit(model) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!windowState.canSubmit(model))
                    .help("Send your pending comments, summary and verdict (⌘↩)")
            }
        }
        .padding(16)
        .frame(width: 440)
        .onChange(of: windowState.summaryText) { _, text in
            windowState.summaryDidChange(text, model: model)
        }
        .onAppear { summaryIsFocused = true }
    }

    private func description(of verdict: Verdict) -> String {
        switch verdict {
        case .comment: "Send your comments without a verdict."
        case .requestChanges: "Ask \(agent) to fix things before the stack moves on."
        case .approve: "Say the stack looks good. \(agentStartingASentence) still won't push or merge."
        }
    }
}

/// A multi-line summary box with a placeholder, drawn like a text field.
private struct SummaryEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        // 4 points of our padding plus the text view's own 5 points of line padding.
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.diffBorder))
            .accessibilityLabel("Review summary")
    }
}

/// One verdict as a radio button, with a line saying what it means.
private struct VerdictOption: View {
    let verdict: Verdict
    let description: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verdict.label)
                        .font(.body.weight(.semibold))
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(verdict.label). \(description)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}
