import SwiftUI

/// Repositories, their stacks, and each stack's layers top first with the trunk last, as
/// `gh stack view` shows them.
struct SidebarView: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState
    @State private var foldedStacks: Set<Int> = []
    @State private var foldedRepositories: Set<Int> = []

    var body: some View {
        // A flat list on purpose: a DisclosureGroup per stack makes SwiftUI's outline diff crash
        // in NSOutlineView when a stack loses layers between reloads.
        List(selection: selection) {
            ForEach(model.repositories, id: \.sidebarID) { repository in
                Section(isExpanded: isExpanded(repository.id)) {
                    if repository.stacks.isEmpty {
                        Text("No stacks yet")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(repository.stacks, id: \.sidebarID) { stack in
                        StackRows(stack: stack, agentName: model.agent.agentName, isFolded: foldedStacks.contains(stack.id)) {
                            if foldedStacks.contains(stack.id) { foldedStacks.remove(stack.id) } else { foldedStacks.insert(stack.id) }
                        } askToRestack: { layer in
                            windowState.askToRestack(layer, in: model)
                        } close: {
                            model.closeStacks([stack.id])
                        }
                    }
                } header: {
                    Label(repository.name, systemImage: "folder")
                        .help(repository.path)
                        .contextMenu {
                            Button("Close \(repository.name)") { model.closeStacks(repository.stacks.map(\.id)) }
                            Button("Close All Stacks") { ReviewCommands.confirmCloseAll(model) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }

    /// A sidebar section left to SwiftUI can arrive folded when it appears while the window is
    /// open, which hides its stacks, so the sidebar owns whether each one is open.
    private func isExpanded(_ repositoryID: Int) -> Binding<Bool> {
        Binding {
            !foldedRepositories.contains(repositoryID)
        } set: { expanded in
            if expanded { foldedRepositories.remove(repositoryID) } else { foldedRepositories.insert(repositoryID) }
        }
    }

    private var selection: Binding<LayerSelection?> {
        Binding {
            model.selection
        } set: { newValue in
            if let newValue, newValue != model.selection { model.select(newValue) }
        }
    }
}

/// One stack as plain list rows: its header, then its layers top first, then the trunk.
private struct StackRows: View {
    let stack: StackItem
    let agentName: String?
    let isFolded: Bool
    let toggleFolded: () -> Void
    let askToRestack: (LayerItem) -> Void
    let close: () -> Void

    /// The badge is the sum of the layer rows' "need you" counts, so the two always agree.
    private var needsYou: Int { stack.layers.reduce(0) { $0 + $1.needsYouCount } }

    var body: some View {
        header
            .selectionDisabled()
            .contextMenu {
                Button("Close Stack", action: close)
            }
        if !isFolded {
            ForEach(stack.layers.sorted { $0.position > $1.position }, id: \.sidebarID) { layer in
                LayerRow(layer: layer, parentBranch: parentBranch(of: layer), agentName: agentName) {
                    askToRestack(layer)
                }
                .padding(.leading, 18)
                .tag(LayerSelection(stackID: stack.id, layerID: layer.id))
            }
            TrunkRow(trunk: stack.trunk)
                .padding(.leading, 18)
                .selectionDisabled()
        }
    }

    private var header: some View {
        Button(action: toggleFolded) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                    .frame(width: 12)
                Image(systemName: "square.stack.3d.up")
                Text(stack.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if needsYou > 0 {
                    Chip(text: NeedsYouText.words(needsYou), symbol: nil, tint: .orange, isSmall: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stack \(stack.name), \(isFolded ? "folded" : "unfolded")")
        .accessibilityValue(needsYou == 1 ? "1 thread needs you" : "\(needsYou) threads need you")
        .help(needsYou == 0 ? "Nothing needs you in this stack" : "Threads in this stack that need you: \(needsYou)")
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
                        .font(.body)
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
                        LineCountsText(additions: layer.additions, deletions: layer.deletions)
                    }
                    if layer.needsYouCount > 0 {
                        NeedsYouText(count: layer.needsYouCount)
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
        .accessibilityActions {
            if layer.status == .needsRestack {
                Button("Ask \(agentName ?? "the agent") to restack", action: askToRestack)
            }
        }
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
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Trunk branch \(trunk)")
        .help("The stack builds on \(trunk)")
    }
}

// The list flattens rows from every level into one outline, so a repository, a stack and a
// layer that share a number would share an identity. These keep the three kinds apart.
private extension RepositoryItem { var sidebarID: String { "repo-\(id)" } }
private extension StackItem { var sidebarID: String { "stack-\(id)" } }
private extension LayerItem { var sidebarID: String { "layer-\(id)" } }
