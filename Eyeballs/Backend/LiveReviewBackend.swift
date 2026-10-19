import AppKit
import SwiftUI
import EyeballsKit
import EyeballsStore

/// The window's real backend: the store, git and the agent socket, through `ReviewService`.
///
/// Every action runs off the main actor, one at a time and in the order you took it, and then
/// the model is read again from the store. Deleting, editing and resolving also change the model
/// at once, so the window never waits on the store to show what you did.
@MainActor
final class LiveReviewBackend: ReviewBackend, ReviewServiceObserver {
    private let model: ReviewWindowModel
    private let service: ReviewService
    private let drafts: DraftStore
    /// Brings the window to the front, taking keyboard focus when asked.
    var presentWindow: (_ focus: Bool) -> Void = { _ in }

    /// The revision ID you view, by stack ID. It follows the agent's newest revision unless you
    /// are writing a comment on lines, whose numbers belong to the revision on screen.
    private var viewing: [Int: Int] = [:]
    private var newestRevisions: [Int: ReviewService.NewestRevision] = [:]
    private var content: ReviewService.StackContent?
    private var loadedDiff: (layerID: Int, revisionID: Int?, diff: LayerDiff)?
    private var liveStreams: [LiveStream] = []
    /// A banner about one stack, cleared when you move to another.
    private var bannerStack: Int?
    private var lastAction: Task<Void, Never>?

    init(model: ReviewWindowModel, service: ReviewService, drafts: DraftStore) {
        self.model = model
        self.service = service
        self.drafts = drafts
    }

    /// Loads every stack from the store, then selects layer 1 of the newest one.
    func start() {
        enqueue { await self.reload() }
    }

    /// Saves drafts that are still on their way to disk, as quitting does.
    func flushDrafts() {
        drafts.flush()
    }

    // MARK: ReviewBackend

    func select(_ selection: LayerSelection) {
        if selection.stackID != model.selection?.stackID, bannerStack != selection.stackID {
            model.banner = nil
            bannerStack = nil
        }
        model.selection = selection
        if viewing[selection.stackID] == nil { viewing[selection.stackID] = newestRevisions[selection.stackID]?.id }
        if model.layer?.layerID != selection.layerID { model.layer = nil }
        model.isLoadingLayer = true
        enqueue { await self.refreshSelection() }
    }

    func selectLayer(atPosition position: Int) {
        guard let stack = model.selectedStack, let layer = stack.layers.first(where: { $0.position == position }) else { return }
        select(LayerSelection(stackID: stack.id, layerID: layer.id))
    }

    func addComment(_ body: String, at anchor: NewThreadAnchor, sendNow: Bool) {
        guard let selection = model.selection, let revision = viewing[selection.stackID] else { return }
        perform { try await self.service.addComment(body, at: anchor, layerID: selection.layerID, viewing: revision, sendNow: sendNow) }
    }

    func reply(_ body: String, to threadID: Int, sendNow: Bool) {
        perform { try await self.service.reply(body, to: threadID, sendNow: sendNow) }
    }

    func editComment(_ commentID: Int, body: String) {
        changeThreads { thread in
            guard let index = thread.comments.firstIndex(where: { $0.id == commentID }) else { return }
            thread.comments[index].body = body
            if !thread.comments[index].isPending { thread.comments[index].isEdited = true }
        }
        perform { try await self.service.editComment(commentID, body: body) }
    }

    func deleteComment(_ commentID: Int) {
        changeThreads { $0.comments.removeAll { $0.id == commentID } }
        perform { try await self.service.deleteComment(commentID) }
    }

    func deleteThread(_ threadID: Int) {
        changeThreads { thread in if thread.id == threadID { thread.comments = [] } }
        perform { try await self.service.deleteThread(threadID) }
    }

    func setResolved(_ resolved: Bool, threadID: Int) {
        changeThreads { thread in
            guard thread.id == threadID else { return }
            thread.isResolved = resolved
            thread.state = resolved ? .resolved : .waitingOnAgent
        }
        perform { try await self.service.setResolved(resolved, threadID: threadID) }
    }

    func draft(for key: DraftKey) -> String {
        guard let selection = model.selection else { return "" }
        return drafts.text(for: key, stack: selection.stackID, layer: selection.layerID)
    }

    func saveDraft(_ text: String, for key: DraftKey) {
        guard let selection = model.selection else { return }
        drafts.set(text, for: key, stack: selection.stackID, layer: selection.layerID)
        if key == .reviewSummary { model.review.summary = text }
    }

    func submitReview(verdict: Verdict, summary: String) {
        guard let stackID = model.selection?.stackID else { return }
        perform { try await self.service.submitReview(stackID: stackID, verdict: ReviewVerdict(verdict), summary: summary) }
    }

    func copyAgentPrompt() {
        guard let stack = model.selectedStack else { return }
        let label = "\(stack.name) (s\(stack.id))"
        let prompt = model.review.lastSubmitted.map {
            "Eyeballs has review \($0.number) for \(label). Run `eyeballs inbox`, then reply to every thread with `eyeballs reply --file -`."
        } ?? "Eyeballs has comments for \(label). Run `eyeballs inbox`, then reply to every thread with `eyeballs reply --file -`."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    func openRepository(at url: URL) {
        enqueue {
            do {
                let opened = try await self.service.openRepository(at: url)
                self.viewing[opened.stack.id] = opened.revisionID
                await self.reload()
                if let layer = self.model.repositories.lazy.flatMap(\.stacks).first(where: { $0.id == opened.stack.id })?.layers
                    .first(where: { $0.position == 1 }) {
                    self.select(LayerSelection(stackID: opened.stack.id, layerID: layer.id))
                }
            } catch {
                self.model.errorMessage = Self.message(for: error)
            }
        }
    }

    func acceptBanner() {
        model.banner = nil
        bannerStack = nil
        guard let stackID = model.selection?.stackID, let latest = newestRevisions[stackID] else { return }
        viewing[stackID] = latest.id
        loadedDiff = nil
        enqueue { await self.reload() }
    }

    // MARK: ReviewServiceObserver

    nonisolated func reviewDidChange(_ change: ReviewChange) {
        Task { @MainActor in self.handle(change) }
    }

    nonisolated func showWindow(forStack stackID: Int?, focus: Bool, select: Bool) {
        Task { @MainActor in
            self.enqueue {
                if let stackID, select ? self.model.selection?.stackID != stackID : self.model.selection == nil,
                   let layer = self.model.repositories.lazy.flatMap(\.stacks).first(where: { $0.id == stackID })?.layers.first(where: { $0.position == 1 }) {
                    self.select(LayerSelection(stackID: stackID, layerID: layer.id))
                }
                self.presentWindow(focus)
            }
        }
    }

    private func handle(_ change: ReviewChange) {
        switch change {
        case .stack:
            enqueue { await self.reload() }
        case .agentReview(let stackID, let number, let created):
            enqueue {
                let selected = self.model.selection?.stackID == stackID
                let follows = !selected || (created && !self.drafts.hasLineDrafts(stack: stackID))
                if follows {
                    self.viewing[stackID] = nil
                    self.loadedDiff = nil
                }
                await self.reload()
                guard selected else { return }
                let name = self.content?.agentName ?? "The agent"
                if !created {
                    self.showBanner(Banner(message: "\(name) ran eyeballs review again, with no new commits since revision \(number).", actionTitle: "OK"),
                                    for: stackID)
                } else if follows {
                    self.showBanner(Banner(message: "Now showing revision \(number), with \(name)'s changes.", actionTitle: "OK"), for: stackID)
                }
            }
        case .listeners(let streams):
            liveStreams = streams
            updateAgentStatus()
        }
    }

    // MARK: Reading the store into the model

    private func reload() async {
        do {
            let overview = try await service.overview(viewing: viewing)
            newestRevisions = overview.newestRevisions
            // A revision you made yourself, by submitting after the branches moved, is the one you meant to look at.
            for (stackID, revision) in newestRevisions where viewing[stackID] == nil || !revision.byAgent { viewing[stackID] = revision.id }
            model.repositories = overview.repositories
            let stacks = overview.repositories.flatMap(\.stacks)
            let needsYou = stacks.reduce(0) { $0 + $1.needsYouCount }
            NSApp.dockTile.badgeLabel = needsYou > 0 ? "\(needsYou)" : nil
            if let selection = model.selection,
               !stacks.contains(where: { $0.id == selection.stackID && $0.layers.contains { $0.id == selection.layerID } }) {
                model.selection = nil
                model.layer = nil
            }
            if model.selection == nil, let stack = stacks.first, let layer = stack.layers.first(where: { $0.position == 1 }) {
                model.selection = LayerSelection(stackID: stack.id, layerID: layer.id)
            }
            await refreshSelection()
        } catch {
            model.errorMessage = Self.message(for: error)
        }
    }

    private func refreshSelection() async {
        guard let selection = model.selection else {
            model.layer = nil
            model.threadsByLayer = [:]
            model.isLoadingLayer = false
            content = nil
            updateAgentStatus()
            return
        }
        let revision = viewing[selection.stackID]
        do {
            let content = try await service.stackContent(stackID: selection.stackID, revisionID: revision)
            guard model.selection == selection else { return }
            self.content = content
            model.threadsByLayer = content.threadsByLayer
            var review = content.review
            review.summary = drafts.text(for: .reviewSummary, stack: selection.stackID, layer: nil)
            model.review = review
            updateAgentStatus()
            offerNewestRevision(of: selection.stackID)

            var diff = loadedDiff.flatMap { $0.layerID == selection.layerID && $0.revisionID == revision ? $0.diff : nil }
            if diff == nil {
                model.isLoadingLayer = true
                diff = try await service.layerDiff(stackID: selection.stackID, layerID: selection.layerID, revisionID: revision)
                guard model.selection == selection else { return }
                loadedDiff = diff.map { (selection.layerID, revision, $0) }
            }
            model.isLoadingLayer = false
            model.layer = LayerContent(layerID: selection.layerID, commits: diff?.commits ?? [], files: diff?.files ?? [],
                                       threads: content.threadsByLayer[selection.layerID] ?? [])
        } catch {
            guard model.selection == selection else { return }
            model.isLoadingLayer = false
            model.errorMessage = Self.message(for: error)
        }
    }

    /// Says when the stack you view has a newer revision than the one on screen.
    private func offerNewestRevision(of stackID: Int) {
        guard let latest = newestRevisions[stackID], let shown = viewing[stackID], latest.id != shown else { return }
        showBanner(Banner(message: "\(content?.agentName ?? "The agent") pushed revision \(latest.number). You are looking at an older one.",
                          actionTitle: "Show Revision \(latest.number)"), for: stackID)
    }

    private func showBanner(_ banner: Banner, for stackID: Int) {
        model.banner = banner
        bannerStack = stackID
    }

    private func updateAgentStatus() {
        guard let content, let listener = content.driverListener else {
            model.agent = .notListening
            return
        }
        let name = content.agentName ?? "Agent"
        if liveStreams.contains(where: { $0.listener == listener }) {
            model.agent = AgentStatus(text: "\(name): listening", isListening: true, agentName: content.agentName)
        } else if let progress = content.progress, progress.replied < progress.total {
            model.agent = AgentStatus(text: "\(name): working, \(progress.replied) of \(progress.total) replied", isListening: true,
                                      agentName: content.agentName)
        } else {
            model.agent = AgentStatus(text: "\(name): not listening", isListening: false, agentName: content.agentName)
        }
    }

    // MARK: Running actions in order

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = lastAction
        lastAction = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        enqueue {
            do {
                try await work()
            } catch {
                self.model.errorMessage = Self.message(for: error)
                await self.reload()
            }
        }
    }

    /// Changes the shown threads at once, before the store confirms. A thread left with no
    /// comments disappears.
    private func changeThreads(_ change: (inout ThreadItem) -> Void) {
        guard var layer = model.layer else { return }
        for index in layer.threads.indices { change(&layer.threads[index]) }
        layer.threads.removeAll { $0.comments.isEmpty }
        model.layer = layer
        model.threadsByLayer[layer.layerID] = layer.threads
    }

    static func message(for error: any Error) -> String {
        let failure = AgentRequestHandler.agentError(error)
        return [failure.message, failure.hint].compactMap { $0 }.joined(separator: " ")
    }
}

#if DEBUG
extension LiveReviewBackend {
    /// The sidebar drawn on its own from the live model, because the window's sidebar is glass,
    /// which a cached display leaves blank.
    func snapshotSidebar(to path: String) {
        let host = NSHostingView(rootView: SidebarView(model: model, windowState: ReviewWindowState())
            .scrollContentBackground(.hidden).foregroundStyle(Color.white).background(Color.black))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

extension LiveReviewBackend: WindowSnapshotting {
    nonisolated func snapshotWindow(to path: String) async -> Bool {
        await MainActor.run {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
            snapshotSidebar(to: path.replacingOccurrences(of: ".png", with: "-sidebar.png"))
            return (try? png.write(to: URL(fileURLWithPath: path))) != nil
        }
    }
}
#endif
