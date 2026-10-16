import SwiftUI

/// The send button and everything around it: pending count, summary, verdict and delivery.
struct ReviewBar: View {
    let model: ReviewWindowModel
    @Bindable var windowState: ReviewWindowState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                status.frame(minWidth: 170, alignment: .leading)
                summaryField.frame(minWidth: 240, idealWidth: 260, maxWidth: .infinity)
                verdictPicker.pickerStyle(.segmented)
                copyButton
                submitButton
            }
            HStack(spacing: 10) {
                status.frame(minWidth: 150, alignment: .leading)
                summaryField.frame(minWidth: 150, idealWidth: 180, maxWidth: .infinity)
                verdictPicker.pickerStyle(.menu)
                copyButton
                submitButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    status
                    Spacer(minLength: 8)
                    copyButton
                    submitButton
                }
                HStack(spacing: 10) {
                    summaryField.frame(minWidth: 100, idealWidth: 120, maxWidth: .infinity)
                    verdictPicker.pickerStyle(.menu)
                }
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: windowState.summaryText) { _, text in
            windowState.summaryDidChange(text, model: model)
        }
    }

    private var summaryField: some View {
        TextField("Summary for the agent (optional)", text: $windowState.summaryText)
            .textFieldStyle(.roundedBorder)
            .onSubmit { windowState.submit(model) }
            .accessibilityLabel("Review summary")
    }

    private var verdictPicker: some View {
        Picker("Verdict", selection: $windowState.verdict) {
            ForEach(Verdict.allCases, id: \.self) { verdict in
                Text(verdict.label).tag(verdict)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("What you want the agent to do with this review")
        .accessibilityLabel("Verdict")
    }

    private var copyButton: some View {
        Button("Copy prompt") { model.copyAgentPrompt() }
            .fixedSize()
            .help("Copy a prompt that tells an agent to read this review")
    }

    private var submitButton: some View {
        Button {
            windowState.submit(model)
        } label: {
            Label("Submit review", systemImage: "paperplane.fill")
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(!windowState.canSubmit(model))
        .help("Send your pending comments, summary and verdict to the agent (⇧⌘↩)")
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: model.review.pendingCommentCount > 0 ? "bubble.left.fill" : "bubble.left")
                    .foregroundStyle(model.review.pendingCommentCount > 0 ? Color.yellow : Color.secondary)
                Text(Self.pendingText(model.review.pendingCommentCount))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            if let submitted = model.review.lastSubmitted {
                HStack(spacing: 5) {
                    Image(systemName: submitted.deliveredAt == nil ? "paperplane" : "checkmark.circle.fill")
                        .foregroundStyle(submitted.deliveredAt == nil ? Color.secondary : Color.green)
                    Text(Self.deliveryText(submitted, agentName: model.agent.agentName))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
        return "Delivered to \(agent) at \(delivered.formatted(date: .omitted, time: .shortened))"
    }
}
