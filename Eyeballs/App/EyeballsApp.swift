import SwiftUI

@main
struct EyeballsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppDefaults.register()
    }

    var body: some Scene {
        Window("Eyeballs", id: "main") {
            MainView(model: appDelegate.session.model, windowState: appDelegate.session.windowState)
                .onOpenURL { appDelegate.session.open($0) }
                .modifier(RemembersWindowOpener(session: appDelegate.session))
        }
        .defaultSize(width: 1320, height: 840)
        .defaultLaunchBehavior(appDelegate.session.launch.isHarnessRun ? .suppressed : .presented)
        .commands {
            ReviewCommands(session: appDelegate.session)
        }

        Window(KeyboardShortcutsView.title, id: KeyboardShortcutsView.windowID) {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var session = AppSession()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if session.usesLiveServices { LiveServices.start(in: session) }
        #if DEBUG
        if let folder = session.launch.screenshotFolder {
            ScreenshotHarness(session: session).run(writingTo: folder)
        } else if session.launch.runsUISelfTest {
            UISelfTest(session: session).run()
        }
        #endif
    }

    // Agents reach the app while its window is closed, so it keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.windowState.pane?.flushAllDrafts()
        session.live?.stop()
    }
}

/// The File, Stack, Go and Review menu items, with the window's keyboard shortcuts.
///
/// The pane's single-letter keys only work while the diff has focus, so every one that moves
/// you around also has a menu item here with a modifier shortcut that works from anywhere.
struct ReviewCommands: Commands {
    let session: AppSession

    private var model: ReviewWindowModel { session.model }
    private var pane: DiffPaneController? { session.windowState.pane }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Install Command Line Tool…") { CommandLineTool.install() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") { RepositoryPicker.choose(for: model) }
                .keyboardShortcut("o")
        }
        CommandMenu("Stack") {
            ForEach(1...9, id: \.self) { position in
                Button(title(forLayerAt: position)) { model.selectLayer(atPosition: position) }
                    .keyboardShortcut(KeyEquivalent(Character(String(position))), modifiers: .command)
                    .disabled(model.selectedStack?.layers.contains { $0.position == position } != true)
            }
            Divider()
            Button("Layer Above") { session.windowState.selectAdjacentLayer(1, in: model) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Layer Below") { session.windowState.selectAdjacentLayer(-1, in: model) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Group {
                Button("Next File") { pane?.moveFile(by: 1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Previous File") { pane?.moveFile(by: -1) }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Button("Next Thread") { pane?.moveThreadFocus(by: 1, needingYouOnly: false) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Button("Previous Thread") { pane?.moveThreadFocus(by: -1, needingYouOnly: false) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                Button("Next Thread That Needs You") { pane?.moveThreadFocus(by: 1, needingYouOnly: true) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            .disabled(model.selection == nil)
        }
        CommandMenu("Review") {
            Button("Finish Review…") { session.windowState.finishReview(model) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.selectedStack == nil)
            Button("Copy Agent Prompt") { model.copyAgentPrompt() }
            Divider()
            Button("Close Stack") { if let stack = model.selectedStack { model.closeStacks([stack.id]) } }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(model.selectedStack == nil)
            Button("Close All Stacks…") { Self.confirmCloseAll(model) }
                .keyboardShortcut("w", modifiers: [.command, .option, .shift])
                .disabled(model.repositories.isEmpty)
        }
        CommandGroup(after: .help) {
            KeyboardShortcutsMenuItem()
        }
    }

    /// Asks first, because closing every stack empties the window at once.
    @MainActor
    static func confirmCloseAll(_ model: ReviewWindowModel) {
        let ids = model.allStackIDs
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Close the stack in Eyeballs?" : "Close all \(ids.count) stacks in Eyeballs?"
        alert.informativeText = "They leave the window, and their comments stay saved. An agent waiting on one is told it closed. When an agent opens the same branches again, they come back as a new stack."
        alert.addButton(withTitle: "Close All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.closeStacks(ids) }
    }

    private func title(forLayerAt position: Int) -> String {
        guard let layer = model.selectedStack?.layers.first(where: { $0.position == position }) else { return "Layer \(position)" }
        return "Layer \(position): \(layer.branch)"
    }
}

/// Hands the window's `openWindow` action to the session, so an agent's `eyeballs review` can
/// open the window again after you closed it.
private struct RemembersWindowOpener: ViewModifier {
    let session: AppSession
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let openWindow = openWindow
            session.openMainWindow = { openWindow(id: "main") }
        }
    }
}

/// Help > Keyboard Shortcuts, as a view of its own so it can read `openWindow`.
private struct KeyboardShortcutsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsView.windowID) }
            .keyboardShortcut("/", modifiers: .command)
    }
}
