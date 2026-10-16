import SwiftUI

/// Repositories, their stacks, and each stack's layers top first with the trunk last, as
/// `gh stack view` shows them.
struct SidebarView: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState

    var body: some View {
        List(selection: selection) {
            ForEach(model.repositories) { repository in
                Section {
                    if repository.stacks.isEmpty {
                        Text("No stacks yet")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(repository.stacks) { stack in
                        StackSection(stack: stack, agentName: model.agent.agentName) { layer in
                            windowState.askToRestack(layer, in: model)
                        }
                    }
                } header: {
                    Label(repository.name, systemImage: "folder")
                        .help(repository.path)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }

    private var selection: Binding<LayerSelection?> {
        Binding {
            model.selection
        } set: { newValue in
            if let newValue, newValue != model.selection { model.select(newValue) }
        }
    }
}

private struct StackSection: View {
    let stack: StackItem
    let agentName: String?
    let askToRestack: (LayerItem) -> Void
    @State private var isExpanded = true

    /// The badge is the sum of the layer rows' "need you" counts, so the two always agree.
    private var needsYou: Int { stack.layers.reduce(0) { $0 + $1.needsYouCount } }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(stack.layers.sorted { $0.position > $1.position }) { layer in
                LayerRow(layer: layer, parentBranch: parentBranch(of: layer), agentName: agentName) {
                    askToRestack(layer)
                }
                .tag(LayerSelection(stackID: stack.id, layerID: layer.id))
            }
            TrunkRow(trunk: stack.trunk)
                .selectionDisabled()
        } label: {
            Label {
                Text(stack.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            } icon: {
                Image(systemName: "square.stack.3d.up")
            }
            .badge(needsYou)
            .accessibilityValue(needsYou == 1 ? "1 thread needs you" : "\(needsYou) threads need you")
            .help(needsYou == 0 ? "Nothing needs you in this stack" : "Threads that need you: \(needsYou)")
        }
    }

    private func parentBranch(of layer: LayerItem) -> String {
        stack.layers.first { $0.position == layer.position - 1 }?.branch ?? stack.trunk
    }
}

struct LayerRow: View {
    let layer: LayerItem
    var parentBranch = "main"
    var agentName: String?
    var askToRestack: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                PositionBadge(position: layer.position)
                StackLine()
                    .padding(.bottom, -StackLine.overlap)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(layer.branch)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    statusChip
                }
                HStack(spacing: 8) {
                    if let number = layer.prNumber {
                        Text("#\(number)")
                    }
                    if layer.additions > 0 || layer.deletions > 0 {
                        HStack(spacing: 4) {
                            Text("+\(layer.additions)").foregroundStyle(Color.diffAddedText)
                            Text("−\(layer.deletions)").foregroundStyle(Color.diffDeletedText)
                        }
                        .font(.caption.weight(.medium).monospaced())
                    }
                    if layer.needsYouCount > 0 {
                        Text(Self.needsYouText(layer.needsYouCount))
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.orange)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.bottom, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Ask \(agentName ?? "the agent") to restack") { askToRestack() }
    }

    /// "Needs restack" says what to do: hover for why, click to ask the agent to restack.
    @ViewBuilder
    private var statusChip: some View {
        if layer.status == .needsRestack {
            Menu {
                Button("Ask \(agentName ?? "the Agent") to Restack", action: askToRestack)
            } label: {
                LayerStatusChip(status: layer.status)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("This layer no longer sits on top of \(parentBranch). Click to ask \(agentName ?? "the agent") to restack it.")
        } else {
            LayerStatusChip(status: layer.status)
        }
    }

    static func needsYouText(_ count: Int) -> String {
        count == 1 ? "1 needs you" : "\(count) need you"
    }

    private var accessibilityText: String {
        var parts = ["Layer \(layer.position)", layer.branch]
        if let number = layer.prNumber { parts.append("pull request \(number)") }
        parts.append("\(layer.additions) added, \(layer.deletions) deleted")
        if layer.needsYouCount > 0 { parts.append(layer.needsYouCount == 1 ? "1 thread needs you" : "\(layer.needsYouCount) threads need you") }
        if let label = layer.status.label { parts.append(label) }
        return parts.joined(separator: ", ")
    }
}

/// The thin line that joins each layer's badge to the one below, down to the trunk.
private struct StackLine: View {
    /// How far the line reaches past its row, across the list's gap to the next row.
    static let overlap: CGFloat = 8

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

private struct PositionBadge: View {
    let position: Int

    var body: some View {
        Text("\(position)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
            .background(Circle().fill(Color.secondary.opacity(0.14)))
            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
    }
}

private struct TrunkRow: View {
    let trunk: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            Text(trunk)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Trunk branch \(trunk)")
        .help("The stack builds on \(trunk)")
    }
}
