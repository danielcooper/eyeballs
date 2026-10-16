import SwiftUI

/// The right-hand column: the diff pane or its empty and loading states, news floating over it,
/// and the review bar along the bottom.
struct DetailColumn: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                DiffPaneView(model: model, windowState: windowState, layer: model.layer,
                             layerItem: model.selectedLayer, stack: model.selectedStack,
                             viewedFiles: windowState.viewedFiles[model.selection?.layerID ?? -1] ?? [:])
                overlay
                notices
            }
            ReviewBar(model: model, windowState: windowState)
        }
        .background(Color.paneBackground)
    }

    /// News such as a newer revision floats over the bottom of the pane, so the code you are
    /// reading never moves when it arrives.
    private var notices: some View {
        VStack(spacing: 8) {
            if let banner = model.banner {
                FloatingNotice(message: banner.message, symbol: "arrow.triangle.2.circlepath.circle.fill", tint: .blue,
                               actionTitle: banner.actionTitle, isProminent: true) { model.acceptBanner() }
            }
            if let message = model.errorMessage {
                FloatingNotice(message: message, symbol: "exclamationmark.triangle.fill", tint: .orange,
                               actionTitle: "Dismiss", isProminent: false) { model.errorMessage = nil }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var overlay: some View {
        if model.selection == nil {
            placeholder {
                ContentUnavailableView(
                    "Pick a layer",
                    systemImage: "square.stack.3d.up",
                    description: Text("Choose a layer of a stack in the sidebar to see its changes."))
            }
        } else if model.layer == nil {
            placeholder {
                if model.isLoadingLayer {
                    ProgressView("Loading layer…").controlSize(.large)
                } else {
                    ContentUnavailableView("This layer isn't loaded", systemImage: "exclamationmark.triangle",
                                           description: Text("Pick it again in the sidebar to retry."))
                }
            }
        } else if let layer = model.layer, layer.files.isEmpty, layer.threads.isEmpty {
            placeholder {
                ContentUnavailableView {
                    Label("No changes in this layer", systemImage: "checkmark.circle")
                } description: {
                    Text(noChangesDescription)
                }
            }
        } else if model.isLoadingLayer {
            VStack {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading layer…").font(.callout)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 16)
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }

    private var noChangesDescription: String {
        guard let layer = model.selectedLayer else { return "There is nothing to review here." }
        return "\(layer.branch) has no commits of its own yet, so there is nothing to review here."
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.paneBackground)
    }
}

/// A capsule of news over the pane, such as a newer revision or an error, with one button.
struct FloatingNotice: View {
    let message: String
    let symbol: String
    let tint: Color
    let actionTitle: String
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            actionButton
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isProminent {
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        } else {
            Button(actionTitle, action: action)
        }
    }
}

/// The toolbar's way through the stack: the layer below, the layer above, and every layer by name.
struct LayerNavigator: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState

    var body: some View {
        if let stack = model.selectedStack, let layer = model.selectedLayer {
            ControlGroup {
                Button {
                    windowState.selectAdjacentLayer(-1, in: model)
                } label: {
                    Label("Layer below", systemImage: "chevron.left")
                }
                .disabled(windowState.adjacentLayer(-1, in: model) == nil)
                .help(helpText(for: windowState.adjacentLayer(-1, in: model), direction: "below", keys: "⇧⌘["))
                Menu {
                    ForEach(stack.layers.sorted { $0.position > $1.position }) { item in
                        Toggle(isOn: Binding(get: { item.id == layer.id }, set: { _ in model.selectLayer(atPosition: item.position) })) {
                            Text("\(item.position) \(item.branch)")
                        }
                    }
                } label: {
                    Text("Layer \(layer.position) of \(stack.layers.count): \(layer.branch)")
                }
                .help("Go to another layer of \(stack.name)")
                Button {
                    windowState.selectAdjacentLayer(1, in: model)
                } label: {
                    Label("Layer above", systemImage: "chevron.right")
                }
                .disabled(windowState.adjacentLayer(1, in: model) == nil)
                .help(helpText(for: windowState.adjacentLayer(1, in: model), direction: "above", keys: "⇧⌘]"))
            }
            .fixedSize()
        }
    }

    private func helpText(for layer: LayerItem?, direction: String, keys: String) -> String {
        guard let layer else { return "There is no layer \(direction) this one" }
        return "Go to layer \(layer.position), \(layer.branch) (\(keys))"
    }
}
