import SwiftUI

/// The main window: the empty state until a repository is open, then the review layout.
struct MainView: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        Group {
            if model.repositories.isEmpty {
                NothingToReviewView(model: model)
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView(model: model)
                } content: {
                    MiddleColumn(model: model, windowState: windowState)
                } detail: {
                    DetailColumn(model: model, windowState: windowState)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .navigationTitle(model.selectedStack?.name ?? "Eyeballs")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AgentStatusCapsule(status: model.agent)
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .onAppear { windowState.loadSummaryIfNeeded(from: model) }
        .onChange(of: model.selection) { windowState.loadSummaryIfNeeded(from: model) }
    }

    private var subtitle: String {
        guard let stack = model.selectedStack else { return "" }
        let layers = stack.layers.count == 1 ? "1 layer" : "\(stack.layers.count) layers"
        guard let revision = stack.revision else { return "No revision yet · \(layers)" }
        return "r\(revision) · \(layers)"
    }
}

/// Says in words whether an agent is listening, with a dot that only repeats the words.
struct AgentStatusCapsule: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.isListening ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 8, height: 8)
            Text(status.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(status.isListening ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent: \(status.text)")
        .help(status.isListening ? "An agent is waiting for your review" : "No agent is waiting. Use Copy prompt to hand the review to one.")
    }
}

struct NothingToReviewView: View {
    let model: ReviewWindowModel

    var body: some View {
        ContentUnavailableView {
            Label("Nothing to review yet", systemImage: "eyes")
        } description: {
            Text("When an agent opens a stack for review, it appears here. You can also open a repository yourself.")
        } actions: {
            Button("Open Repository…") { RepositoryPicker.choose(for: model) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Asks for a repository folder and hands it to the backend.
@MainActor
enum RepositoryPicker {
    static func choose(for model: ReviewWindowModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a git repository to review."
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.openRepository(at: url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            finish(panel.runModal())
        }
    }
}
