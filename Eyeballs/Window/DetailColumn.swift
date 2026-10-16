import SwiftUI

/// The right-hand column: news in a row of its own at the top, the diff pane or its empty and
/// loading states, and the review bar along the bottom.
struct DetailColumn: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState

    var body: some View {
        VStack(spacing: 0) {
            notices
            ZStack(alignment: .top) {
                DiffPaneView(model: model, windowState: windowState, layer: model.layer,
                             layerItem: model.selectedLayer, stack: model.selectedStack,
                             viewedFiles: windowState.viewedFiles[model.selection?.layerID ?? -1] ?? [:])
                overlay
            }
            ReviewBar(model: model, windowState: windowState)
        }
        .background(Color.paneBackground)
    }

    /// News such as a newer revision sits above the diff, never over it, so it hides no code or
    /// controls. Taking it in is always your choice.
    @ViewBuilder
    private var notices: some View {
        if model.banner != nil || model.errorMessage != nil {
            VStack(spacing: 8) {
                if let banner = model.banner {
                    NoticeBanner(message: banner.message, symbol: "arrow.triangle.2.circlepath.circle.fill", tint: .accentColor, actions: [
                        NoticeBanner.Action(title: banner.actionTitle, isProminent: true) { model.acceptBanner() },
                    ])
                }
                if let message = model.errorMessage {
                    NoticeBanner(message: message, symbol: "exclamationmark.triangle.fill", tint: .orange, actions: errorActions)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.paneBackground)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var errorActions: [NoticeBanner.Action] {
        var actions: [NoticeBanner.Action] = []
        if model.selection != nil {
            actions.append(NoticeBanner.Action(title: "Try Again", help: "Read the stack again") { windowState.retryAfterError(model) })
        }
        actions.append(NoticeBanner.Action(title: "Dismiss") { model.errorMessage = nil })
        return actions
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

/// One piece of news above the diff, such as a newer revision or an error, with its buttons.
struct NoticeBanner: View {
    struct Action: Identifiable {
        var title: String
        var isProminent = false
        var help: String?
        var run: () -> Void
        var id: String { title }
    }

    let message: String
    let symbol: String
    let tint: Color
    let actions: [Action]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(1...3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(actions) { action in
                    button(for: action)
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func button(for action: Action) -> some View {
        if action.isProminent {
            Button(action.title, action: action.run).buttonStyle(.borderedProminent).help(action.help ?? "")
        } else {
            Button(action.title, action: action.run).help(action.help ?? "")
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
