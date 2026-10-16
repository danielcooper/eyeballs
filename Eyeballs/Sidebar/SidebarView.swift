import SwiftUI

/// Repositories, their stacks, and each stack's layers top first with the trunk last, as
/// `gh stack view` shows them.
struct SidebarView: View {
    let model: ReviewWindowModel

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
                        StackSection(stack: stack)
                    }
                } header: {
                    Label(repository.name, systemImage: "folder")
                        .help(repository.path)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
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
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(stack.layers.sorted { $0.position > $1.position }) { layer in
                LayerRow(layer: layer)
                    .tag(LayerSelection(stackID: stack.id, layerID: layer.id))
            }
            TrunkRow(trunk: stack.trunk)
                .selectionDisabled()
        } label: {
            Label {
                Text(stack.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            } icon: {
                Image(systemName: "square.stack.3d.up")
            }
            .badge(stack.needsYouCount)
            .accessibilityValue(stack.needsYouCount == 1 ? "1 thread needs you" : "\(stack.needsYouCount) threads need you")
            .help(stack.needsYouCount == 0 ? "Nothing needs you in this stack" : "Threads that need you: \(stack.needsYouCount)")
        }
    }
}

struct LayerRow: View {
    let layer: LayerItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PositionBadge(position: layer.position)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(layer.branch)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    LayerStatusChip(status: layer.status)
                }
                HStack(spacing: 6) {
                    if let number = layer.prNumber {
                        Text("#\(number)")
                    }
                    HStack(spacing: 3) {
                        Text("+\(layer.additions)").foregroundStyle(Color.diffAddedText)
                        Text("−\(layer.deletions)").foregroundStyle(Color.diffDeletedText)
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    if layer.openThreadCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left")
                            Text("\(layer.openThreadCount)")
                        }
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["Layer \(layer.position)", layer.branch]
        if let number = layer.prNumber { parts.append("pull request \(number)") }
        parts.append("\(layer.additions) added, \(layer.deletions) deleted")
        parts.append(layer.openThreadCount == 1 ? "1 open thread" : "\(layer.openThreadCount) open threads")
        if let label = layer.status.label { parts.append(label) }
        return parts.joined(separator: ", ")
    }
}

private struct PositionBadge: View {
    let position: Int

    var body: some View {
        Text("\(position)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.secondary.opacity(0.14)))
            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
    }
}

private struct TrunkRow: View {
    let trunk: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
            Text(trunk)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Trunk branch \(trunk)")
        .help("The stack builds on \(trunk)")
    }
}
