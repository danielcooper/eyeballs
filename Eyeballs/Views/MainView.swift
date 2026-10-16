import SwiftUI

/// The main window: the empty state until a repository is open, then the review layout.
struct MainView: View {
    /// Below this width the sidebar hides itself, so the diff keeps room to read. The toolbar's
    /// layer navigator still moves you through the stack.
    nonisolated static let threeColumnWidth: CGFloat = 1250

    let model: ReviewWindowModel
    let windowState: ReviewWindowState
    @State private var columns = NavigationSplitViewVisibility.all
    /// True while the sidebar is hidden only because the window is narrow.
    @State private var sidebarHiddenForWidth = false

    var body: some View {
        Group {
            if model.repositories.isEmpty {
                NothingToReviewView(model: model)
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView(model: model, windowState: windowState)
                } content: {
                    MiddleColumn(model: model, windowState: windowState)
                } detail: {
                    DetailColumn(model: model, windowState: windowState)
                }
                .navigationSplitViewStyle(.balanced)
                .onGeometryChange(for: Bool.self) { $0.size.width < Self.threeColumnWidth } action: { isNarrow in
                    fitColumns(narrow: isNarrow)
                }
                .onChange(of: columns) {
                    if columns == .all { sidebarHiddenForWidth = false }
                }
            }
        }
        .navigationTitle(model.selectedStack?.name ?? "Eyeballs")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                LayerNavigator(model: model, windowState: windowState)
            }
            ToolbarItem(placement: .primaryAction) {
                AgentStatusMenu(model: model)
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .onAppear { windowState.loadSummaryIfNeeded(from: model) }
        .onChange(of: model.selection) { windowState.loadSummaryIfNeeded(from: model) }
    }

    /// Hides the sidebar when the window gets narrow, and shows it again when the window widens,
    /// unless you opened it yourself in between.
    private func fitColumns(narrow: Bool) {
        if narrow, columns == .all {
            columns = .doubleColumn
            sidebarHiddenForWidth = true
        } else if !narrow, sidebarHiddenForWidth {
            columns = .all
        }
    }

    private var subtitle: String {
        guard let stack = model.selectedStack else { return "" }
        let layers = stack.layers.count == 1 ? "1 layer" : "\(stack.layers.count) layers"
        guard let revision = stack.revision else { return "No revision yet · \(layers)" }
        return "r\(revision) · \(layers)"
    }
}

/// Says in words whether an agent is listening, with a dot that only repeats the words. Its
/// menu holds Copy prompt, which the review bar shows only while no agent is listening.
struct AgentStatusMenu: View {
    let model: ReviewWindowModel

    private var status: AgentStatus { model.agent }

    var body: some View {
        Menu {
            Text(status.text)
            Divider()
            Button("Copy Agent Prompt") { model.copyAgentPrompt() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .imageScale(.small)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(status.isListening ? Color.green : Color.secondary)
                Text(status.text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(status.isListening ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .fixedSize()
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Agent: \(status.text)")
        .help(status.isListening ? "An agent is waiting for your review. Click for Copy prompt." : "No agent is waiting. Click to copy a prompt that hands the review to one.")
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
