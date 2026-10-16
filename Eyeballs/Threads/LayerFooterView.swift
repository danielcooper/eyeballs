import SwiftUI

/// What the end-of-layer footer can ask the window to do.
struct FooterActions {
    /// Goes to the layer at a position in the stack.
    var showLayer: @MainActor (Int) -> Void = { _ in }
    var finishReview: @MainActor () -> Void = {}
}

/// The last row of the pane. It says the layer has ended and offers the way on: the next
/// layer up, a layer with threads that need you, or finishing the review.
struct LayerFooterView: View {
    static let height: CGFloat = 152
    static let placeholder = LayerFooterView(content: FooterContent(branch: "", nextLayer: nil, layerNeedingYou: nil), actions: FooterActions())

    let content: FooterContent
    let actions: FooterActions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: content.nextLayer == nil ? "flag.checkered" : "arrow.up.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action
                .fixedSize()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardHeader))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.diffBorder))
        .frame(maxWidth: ThreadLayout.maxCardWidth, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.paneBackground)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        content.nextLayer == nil ? "End of \(content.branch), the top of the stack" : "End of \(content.branch)"
    }

    private var detail: String {
        var sentences: [String] = []
        if let next = content.nextLayer {
            sentences.append(next.needsYouCount > 0
                ? "Next: \(next.position) \(next.branch), where \(Self.needYou(next.needsYouCount))."
                : "Next: \(next.position) \(next.branch).")
        }
        if let other = content.layerNeedingYou {
            sentences.append("\(Self.needYou(other.needsYouCount)) on \(other.position) \(other.branch).")
        } else if content.nextLayer == nil {
            sentences.append("Finish the review when you're ready.")
        }
        return sentences.joined(separator: " ")
    }

    @ViewBuilder
    private var action: some View {
        if let next = content.nextLayer {
            Button {
                actions.showLayer(next.position)
            } label: {
                Label("Next layer", systemImage: "arrow.up")
            }
            .help("Go to layer \(next.position), \(next.branch) (⇧⌘])")
        } else if let other = content.layerNeedingYou {
            Button("Go to \(other.branch)") { actions.showLayer(other.position) }
                .help("Go to layer \(other.position), \(other.branch)")
        } else {
            Button("Finish review…", action: actions.finishReview)
                .help("Add a summary, pick a verdict and send your review (⇧⌘↩)")
        }
    }

    private static func needYou(_ count: Int) -> String {
        count == 1 ? "1 thread needs you" : "\(count) threads need you"
    }
}
