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
        .navigationSplitViewColumnWidth(min: 560, ideal: 840)
    }

    /// News such as a newer revision sits above the diff, never over it, so it hides no code or
    /// controls. Taking it in is always your choice.
    @ViewBuilder
    private var notices: some View {
        if model.banner != nil || model.errorMessage != nil || model.commitFocus != nil {
            VStack(spacing: 8) {
                if let commit = model.commitFocus {
                    NoticeBanner(
                        message: "Showing one commit, \(commit.sha.prefix(7)): \(commit.subject). To comment, show all changes.",
                        symbol: "smallcircle.filled.circle", tint: .secondary, actions: [
                            NoticeBanner.Action(title: "Show All Changes", isProminent: true) { model.focusCommit(nil) },
                        ])
                }
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
            if model.isLoadingLayer {
                placeholder { LoadingDiff() }
            } else {
                placeholder {
                    ContentUnavailableView("This layer isn't loaded", systemImage: "exclamationmark.triangle",
                                           description: Text("Pick it again in the sidebar to retry."))
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

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.paneBackground)
    }
}

/// Grey stand-ins for the diff while a layer loads, drawn like the file list's stand-ins, so the
/// two columns show one loading state.
private struct LoadingDiff: View {
    private static let lineLengths = [28, 44, 36, 52, 20, 0, 40, 60, 32, 48, 24, 0, 36, 56, 44, 28]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LAYER 2 OF 3")
                    .font(.subheadline.weight(.semibold))
                Text("placeholder-layer")
                    .font(.title3.weight(.semibold))
                Text("Builds on placeholder")
                    .font(.callout)
            }
            .padding(16)
            HStack {
                Text("Sources/Placeholder/File.swift  +24 −6")
                    .font(.callout.monospaced())
                Spacer()
            }
            .padding(.horizontal, 52)
            .frame(height: FileHeaderView.height)
            .background(Color(nsColor: DiffColors.fileHeader))
            ForEach(Array(Self.lineLengths.enumerated()), id: \.offset) { index, length in
                HStack(spacing: 24) {
                    Text("\(index + 10)").frame(width: 28, alignment: .trailing)
                    Text("\(index + 12)").frame(width: 28, alignment: .trailing)
                    Text(String(repeating: "x", count: max(1, length)))
                        .opacity(length == 0 ? 0 : 1)
                }
                .font(.callout.monospaced())
                .padding(.horizontal, 12)
                .frame(height: 20)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading the layer")
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

/// The toolbar's way through the stack, drawn top first like the sidebar: the layer above,
/// every layer by name, and the layer below.
struct LayerNavigator: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState

    var body: some View {
        if let stack = model.selectedStack, let layer = model.selectedLayer {
            ControlGroup {
                Button {
                    windowState.selectAdjacentLayer(1, in: model)
                } label: {
                    Label("Layer above", systemImage: "chevron.up")
                }
                .disabled(windowState.adjacentLayer(1, in: model) == nil)
                .help(helpText(for: windowState.adjacentLayer(1, in: model), direction: "above", keys: "⇧⌘]"))
                Menu {
                    ForEach(stack.layers.sorted { $0.position > $1.position }) { item in
                        Toggle(isOn: Binding(get: { item.id == layer.id }, set: { _ in model.selectLayer(atPosition: item.position) })) {
                            Text("Layer \(item.position) · \(item.branch)")
                        }
                    }
                } label: {
                    Text("Layer \(layer.position) of \(stack.layers.count): \(layer.branch)")
                }
                .help("Go to another layer of \(stack.name)")
                Button {
                    windowState.selectAdjacentLayer(-1, in: model)
                } label: {
                    Label("Layer below", systemImage: "chevron.down")
                }
                .disabled(windowState.adjacentLayer(-1, in: model) == nil)
                .help(helpText(for: windowState.adjacentLayer(-1, in: model), direction: "below", keys: "⇧⌘["))
            }
            .fixedSize()
        }
    }

    private func helpText(for layer: LayerItem?, direction: String, keys: String) -> String {
        guard let layer else { return "There is no layer \(direction) this one" }
        return "Go to the layer \(direction), layer \(layer.position), \(layer.branch) (\(keys))"
    }
}
