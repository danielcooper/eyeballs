import SwiftUI

/// The right-hand column: the banner, the diff pane or its empty and loading states, and the
/// review bar along the bottom.
struct DetailColumn: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                BannerStrip(banner: banner) { model.acceptBanner() }
            }
            if let message = model.errorMessage {
                ErrorStrip(message: message) { model.errorMessage = nil }
            }
            ZStack {
                DiffPaneView(model: model, windowState: windowState, layer: model.layer,
                             layerItem: model.selectedLayer, stack: model.selectedStack)
                overlay
            }
            ReviewBar(model: model, windowState: windowState)
        }
        .background(Color.paneBackground)
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
                .padding(.horizontal, 14)
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

/// A strip under the toolbar, for news such as a newer revision, with its action button.
struct BannerStrip: View {
    let banner: Banner
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.blue)
            Text(banner.message)
                .font(.system(size: 12.5))
                .lineLimit(2)
            Spacer(minLength: 12)
            Button(banner.actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.09), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

struct ErrorStrip: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12.5))
                .lineLimit(3)
            Spacer(minLength: 12)
            Button("Dismiss", action: dismiss)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
    }
}
